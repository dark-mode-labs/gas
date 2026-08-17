defmodule Gas.Compiler.Codegen do
  @moduledoc """
  Compiles a parsed template into an Elixir module, so rendering is a function
  call instead of an AST walk. Assigns stay a runtime map.

  A whole `Gas.Context` is threaded through the generated functions, not a bare
  map: `{% increment %}` writes `counter_vars`, `{% for %}` writes
  `iteration_vars` and `registers`, and a read resolves across all three.

  Uncovered nodes fall back to `Gas.render/3` and a raise re-runs the whole tree
  through the interpreter, so output is identical either way. `source/2` reports
  how much of a tree compiled.
  """

  alias Gas.{Literal, Object, Text, Variable}
  alias Gas.Tags.{AssignTag, CaptureTag, CaseTag, ForTag, IfTag}

  @filters Gas.Filters.Filter.__info__(:functions)
           |> Enum.map(fn {name, arity} -> {to_string(name), arity} end)
           |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  @operators [:==, :!=, :<>, :>, :<, :>=, :<=, :contains]

  @module_limit 2_000

  # Filters safe at compile time: deterministic, depending only on their arguments.
  @pure_filters ~w(append prepend upcase downcase capitalize strip lstrip rstrip
                   join push push_if split first last size default replace
                   replace_first remove remove_first plus minus times divided_by
                   modulo abs at_least at_most ceil floor round sort sort_natural
                   reverse uniq compact concat slice truncate truncatewords
                   escape escape_once url_encode url_decode strip_html
                   strip_newlines newline_to_br keys values to_str to_integer)

  @doc """
  Compiles `tree`, reusing the module from a previous call for the same tree.

  Bucketed by hash and matched on the tree itself, so colliding trees each keep
  their own module.
  """
  @spec compile_cached(list, map, keyword) :: {:ok, module} | :error
  def compile_cached(tree, known \\ %{}, opts \\ []) do
    tree = List.wrap(tree)
    hash = :erlang.phash2({tree, known})
    key = {__MODULE__, :tree, hash}
    bucket = :persistent_term.get(key, [])

    case List.keyfind(bucket, {tree, known}, 0) do
      {_, module} ->
        {:ok, module}

      nil ->
        compile_new(tree, known, opts, hash, key, bucket)
    end
  end

  # A loaded module is never purged, and liquid-bearing settings are merchant-editable.
  defp compile_new(tree, known, opts, hash, key, bucket) do
    if compiled_count() < Keyword.get(opts, :module_limit, @module_limit) do
      name = "T#{hash}_#{System.unique_integer([:positive])}"

      case compile(tree, Module.concat(Gas.Compiled, name), known, opts) do
        {:ok, module} ->
          :persistent_term.put(key, [{{tree, known}, module} | bucket])
          :persistent_term.put({__MODULE__, :count}, compiled_count() + 1)
          {:ok, module}

        :error ->
          :error
      end
    else
      Gas.Compiler.Runtime.log_once({__MODULE__, :limit_reported}, fn ->
        "gas: #{@module_limit} compiled templates reached; the rest render interpreted"
      end)

      :error
    end
  end

  defp compiled_count, do: :persistent_term.get({__MODULE__, :count}, 0)

  @doc "Builds and loads a module for `tree`. Returns `{:ok, module}` or `:error`."
  @spec compile(list, module, map, keyword) :: {:ok, module} | :error
  def compile(tree, mod, known \\ %{}, opts \\ []) do
    tree = List.wrap(tree)
    {source, nodes, _covered, _total, constant} = build(tree, mod, known, opts)
    [{module, _bin}] = Code.compile_string(source)
    :persistent_term.put({__MODULE__, module}, {tree, nodes})
    if constant, do: :persistent_term.put({__MODULE__, :const, module}, constant_value(constant))
    {:ok, module}
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  @doc """
  Generated source plus `{fallback_nodes, compiled_count, total_count}`.

  `known` binds variables to values fixed for the life of the module — a page's
  layout tree, its settings. Reads of those fold to literals and the conditions
  over them pick a branch at compile time, so a module built with a non-empty
  `known` is only valid for those exact bindings.
  """
  @spec source(list, module, map, keyword) :: {binary, tuple, non_neg_integer, non_neg_integer}
  def source(tree, mod, known \\ %{}, opts \\ []) do
    {src, nodes, covered, total, _constant} = build(tree, mod, known, opts)
    {src, nodes, covered, total}
  end

  # The output a compiled module always produces, or nil if it varies.
  defp constant_output(module), do: :persistent_term.get({__MODULE__, :const, module}, nil)

  @doc """
  An argument's value if `known` fixes it at compile time, else `:unknown`.

  For `Gas.Tag.gas_rewrite/2` implementations deciding whether the value their
  behaviour turns on is already settled.
  """
  @spec constant_argument(term, map) :: {:ok, term} | :unknown
  def constant_argument(argument, known), do: const_value(argument, known)

  defp build(tree, mod, known, opts) do
    state = new_state(known, opts)

    {entry, state} = body(List.wrap(tree), state)

    src = """
    defmodule #{inspect(mod)} do
      @moduledoc false
      import Gas.Compiler.Runtime, warn: false
      @data_key {Gas.Compiler.Codegen, __MODULE__}

      # Generated code assumes the default matcher, scopes and lax variables.
      def render(%Gas.Context{matcher_module: Gas.Matcher, strict_variables: false} = ctx, opts) do
        if ctx.scopes == Gas.Context.default_scopes() do
          try do
            #{entry}(ctx, opts)
          rescue
            error ->
              report_fallback(__MODULE__, error, __STACKTRACE__)
              interpret_all(ctx, opts)
          end
        else
          interpret_all(ctx, opts)
        end
      end

      def render(%Gas.Context{} = ctx, opts), do: interpret_all(ctx, opts)

    #{state.funs |> Enum.reverse() |> live_funs(entry) |> Enum.join("\n")}
      def interpret_all(ctx, opts) do
        {tree, _nodes} = :persistent_term.get(@data_key)
        Gas.render(tree, ctx, opts)
      end

      def interpret(index, ctx, opts) do
        {_tree, nodes} = :persistent_term.get(@data_key)
        Gas.render([elem(nodes, index)], ctx, opts)
      end

      # Mirrors Gas.Context.scan_scopes: a found-nil keeps looking, not wins.
      def get(c, keys, o), do: resolve(lookup(c, keys), c, o)

      def lookup(%{iteration_vars: iteration} = c, keys) when map_size(iteration) == 0 do
        case walk(c.vars, keys) do
          nil -> counters(c, keys)
          value -> value
        end
      end

      def lookup(c, keys) do
        case walk(c.iteration_vars, keys) do
          nil ->
            case walk(c.vars, keys) do
              nil -> counters(c, keys)
              value -> value
            end

          value ->
            value
        end
      end

      def counters(%{counter_vars: counters}, _keys) when map_size(counters) == 0, do: nil
      def counters(c, keys), do: walk(c.counter_vars, keys)

      def walk(value, []), do: value

      def walk(value, [key]) when is_map(value) and not is_struct(value) do
        case value do
          %{^key => found} -> found
          _ when key == "size" -> map_size(value)
          _ -> nil
        end
      end

      def walk(value, [key | rest]) when is_map(value) and not is_struct(value) do
        case value do
          %{^key => found} -> walk(found, rest)
          _ when key == "size" -> walk(map_size(value), rest)
          _ -> nil
        end
      end

      def walk(value, keys), do: unwrap(Gas.Matcher.match(value, keys))

      def unwrap({:ok, value}), do: value
      def unwrap(_other), do: nil

      def put_var(c, name, value), do: %{c | vars: Map.put(c.vars, name, value)}

      def str(value) when is_binary(value), do: value
      def str(value), do: Gas.Argument.stringify!(value)

      def truthy(nil), do: false
      def truthy(false), do: false
      def truthy(_value), do: true

      # Two binaries reach only evaluator clauses that are Erlang equality.
      def compare(left, :==, right) when is_binary(left) and is_binary(right), do: left == right
      def compare(left, :!=, right) when is_binary(left) and is_binary(right), do: left != right

      def compare(left, operator, right) do
        {:ok, result} = Gas.BinaryCondition.eval({left, operator, right})
        result
      end

    end
    """

    {src, List.to_tuple(Enum.reverse(state.data)), state.nodes - state.fallbacks, state.nodes,
     state.const_bodies[entry]}
  end

  # A branch folded to a constant orphans its function, so unreachable defs go.
  defp live_funs(funs, entry) do
    reachable = reachable_funs(funs, MapSet.new([entry]))
    Enum.filter(funs, &MapSet.member?(reachable, fun_name(&1)))
  end

  defp reachable_funs(funs, reached) do
    grown =
      Enum.reduce(funs, reached, fn fun, acc ->
        if MapSet.member?(acc, fun_name(fun)), do: MapSet.union(acc, calls(fun)), else: acc
      end)

    if MapSet.size(grown) == MapSet.size(reached), do: grown, else: reachable_funs(funs, grown)
  end

  defp fun_name(fun) do
    [_, name] = Regex.run(~r/defp (b\d+)\(/, fun)
    name
  end

  # Permissive by design: a false match keeps a dead function, a miss drops a live one.
  defp calls(fun) do
    ~r/\b(b\d+)\(/ |> Regex.scan(fun) |> MapSet.new(&Enum.at(&1, 1))
  end

  # ---- a node list becomes a function returning {iodata, context} ---------
  defp body(nodes, state) do
    name = "b#{state.n}"
    state = %{state | n: state.n + 1}

    {steps, state, slot} =
      Enum.reduce(nodes, {[], state, 0}, fn node, {steps, st, slot} ->
        st = %{st | nodes: st.nodes + 1}
        {line, out, st, next} = emit(node, st, slot)

        step = %{
          line: line,
          out: out,
          const?: constant_out?(line, out),
          throws?: loop_control?(node),
          ctx: "c#{next}"
        }

        {[step | steps], st, next}
      end)

    steps = Enum.reverse(steps)
    lines = steps |> Enum.map(& &1.line) |> Enum.reject(&(&1 == ""))
    outs = Enum.map(steps, &{&1.out, &1.const?})
    merged = merge_constants(outs)

    state =
      if lines == [] and Enum.all?(outs, &elem(&1, 1)) do
        constant = if merged == [], do: ~s(""), else: Enum.join(merged, " <> ")
        %{state | const_bodies: Map.put(state.const_bodies, name, constant)}
      else
        state
      end

    fun =
      if Enum.any?(steps, & &1.throws?) do
        incremental_body(name, steps, "c#{slot}")
      else
        """
          defp #{name}(c0, o) do
            _ = o
            #{Enum.join(lines, "\n        ")}
            {[#{Enum.join(merged, ", ")}], c#{slot}}
          end
        """
      end

    {name, %{state | funs: [fun | state.funs]}}
  end

  # `break`/`continue` carry prior output, so a throwing body hands its accumulator on.
  defp incremental_body(name, steps, exit_ctx) do
    {body, _acc} =
      steps
      |> Enum.with_index(1)
      |> Enum.reduce({[], "acc0"}, fn {step, index}, {lines, acc} ->
        next_acc = "acc#{index}"

        line =
          cond do
            step.line == "" -> ""
            step.throws? -> guarded_step(step, acc)
            true -> step.line
          end

        {lines ++ [line, "#{next_acc} = [#{acc}, #{step.out}]"], next_acc}
      end)

    """
      defp #{name}(c0, o) do
        _ = o
        acc0 = []
        #{body |> Enum.reject(&(&1 == "")) |> Enum.join("\n        ")}
        {acc#{length(steps)}, #{exit_ctx}}
      end
    """
  end

  # try/catch does not export its bindings, so the step returns them.
  defp guarded_step(step, acc) do
    """
    {#{step.out}, #{step.ctx}} =
              try do
                #{step.line}
                {#{step.out}, #{step.ctx}}
              catch
                {:break_exp, r, c} -> throw({:break_exp, [#{acc}, r], c})
                {:continue_exp, r, c} -> throw({:continue_exp, [#{acc}, r], c})
              end\
    """
  end

  # Only text and folded interpolations emit literals, so a literal means constant.
  defp constant_out?("", "[]"), do: true
  defp constant_out?("", out), do: String.starts_with?(out, "\"")
  defp constant_out?(_line, _out), do: false

  # Neighbouring constants join with `<>`, which the compiler folds into one literal.
  defp merge_constants(outs) do
    outs
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.flat_map(&merge_chunk/1)
  end

  defp merge_chunk([{_out, false} | _] = chunk), do: Enum.map(chunk, &elem(&1, 0))
  defp merge_chunk(chunk), do: [Enum.map_join(chunk, " <> ", &literal_source/1)]

  defp literal_source({"[]", _}), do: "\"\""
  defp literal_source({out, _}), do: out

  defp fallback(state, slot, node) do
    index = state.fallbacks
    # An interpreted node may assign anything, so bindings survive only if it says not.
    known = if assigns_nothing?(node), do: state.known, else: %{}
    state = %{state | data: [node | state.data], fallbacks: index + 1, known: known}

    {"{o#{slot}, c#{slot + 1}} = interpret(#{index}, c#{slot}, o)", "o#{slot}", state, slot + 1}
  end

  # ---- emit --------------------------------------------------------------
  defp emit(%Text{text: text}, state, slot), do: {"", literal(text), state, slot}

  defp emit(%Gas.Tags.NoOpTag{}, state, slot), do: {"", "[]", state, slot}

  defp emit(%Object{argument: argument, filters: filters} = node, state, slot) do
    case const_expression(argument, filters, state.known) do
      {:ok, value} -> {"", literal(Gas.Argument.stringify!(value)), state, slot}
      :unknown -> emit_object(node, argument, filters, state, slot)
    end
  end

  defp emit(%AssignTag{argument: target, object: %Object{} = obj} = node, state, slot) do
    case expression(obj.argument, obj.filters, "c#{slot}", state) do
      {:ok, code, state} ->
        name = to_string(target)
        state = rebind(state, name, const_assign(obj, state.known))
        {"c#{slot + 1} = put_var(c#{slot}, #{literal(name)}, #{code})", "[]", state, slot + 1}

      :error ->
        fallback(state, slot, node)
    end
  end

  defp emit(%CaptureTag{argument: target, body: inner}, state, slot) do
    {fun, state} = body(List.wrap(inner), state)
    name = to_string(target)
    state = forget(state, name)

    line =
      "{cap#{slot}, cc#{slot}} = #{fun}(c#{slot}, o); " <>
        "c#{slot + 1} = put_var(cc#{slot}, #{literal(name)}, IO.iodata_to_binary(cap#{slot}))"

    {line, "[]", state, slot + 1}
  end

  defp emit(%IfTag{tag_name: kind} = node, state, slot) when kind in [:if, :unless] do
    first = if kind == :if, do: node.condition, else: {:negate, node.condition}
    chain = [{first, node.body} | List.wrap(node.elsifs)] ++ [{:else, node.else_body}]

    case fold_chain(chain, state.known) do
      {:taken, branch} ->
        {fun, state} = body(List.wrap(branch), state)

        emit_body(fun, state, slot)

      :unknown ->
        emit_if(node, kind, state, slot)
    end
  end

  defp emit(%Gas.Tags.RenderTag{} = node, state, slot) do
    case inline_render(node, state, slot) do
      {:ok, line, out, state, slot} -> {line, out, state, slot}
      :error -> emit_render(node, state, slot)
    end
  end

  defp emit(%CaseTag{} = node, state, slot) do
    case fold_case(node, state.known) do
      {:taken, branch} ->
        {fun, state} = body(List.wrap(branch), state)

        emit_body(fun, state, slot)

      :unknown ->
        emit_case(node, state, slot)
    end
  end

  defp emit(%ForTag{variable: %Variable{identifier: key}} = node, state, slot) do
    case unroll_for(node, key, state, slot) do
      {:ok, line, out, state, slot} -> {line, out, state, slot}
      :error -> emit_for(node, key, state, slot)
    end
  end

  defp emit(node, state, slot) do
    if renders_nothing?(node) do
      {"", "[]", state, slot}
    else
      case rewrite(node, state.known) do
        {:ok, replacement} -> emit_rewritten(replacement, state, slot)
        :error -> fallback(state, slot, node)
      end
    end
  end

  # A body whose whole output is fixed is inlined at the call site instead.
  defp emit_body(fun, state, slot) do
    case state.const_bodies[fun] do
      nil -> {"{o#{slot}, c#{slot + 1}} = #{fun}(c#{slot}, o)", "o#{slot}", state, slot + 1}
      literal -> {"", literal, state, slot}
    end
  end

  # A rewritten tag contributes output only, so its context changes are discarded.
  defp emit_rewritten(replacement, state, slot) do
    {fun, state} = body(List.wrap(replacement), state)

    case state.const_bodies[fun] do
      nil ->
        line = "{o#{slot}, _} = #{fun}(c#{slot}, o)\n        c#{slot + 1} = c#{slot}"
        {line, "o#{slot}", state, slot + 1}

      literal ->
        {"", literal, state, slot}
    end
  end

  defp rewrite(%module{} = node, known) do
    if Code.ensure_loaded?(module) and function_exported?(module, :gas_rewrite, 2) do
      module.gas_rewrite(node, known)
    else
      :error
    end
  end

  defp rewrite(_node, _known), do: :error

  defp emit_case(node, state, slot) do
    whens = for {arguments, branch} <- node.cases, arguments != :else, do: {arguments, branch}
    else_branch = node.cases |> Enum.filter(&match?({:else, _}, &1)) |> List.last()

    subject = "sub#{slot}"

    with {:ok, code, state} <- expression(node.argument, [], "c#{slot}", state),
         {:ok, clauses, state} <- case_clauses(whens, subject, "c#{slot}", state) do
      {else_fun, state} = conditional_body(else_branch |> case_body() |> List.wrap(), state)

      {tail, state} =
        clauses
        |> Enum.reverse()
        |> Enum.reduce({"#{else_fun}(c#{slot}, o)", state}, fn {test, branch}, {acc, st} ->
          {fun, st} = conditional_body(List.wrap(branch), st)
          {"if #{test} do #{fun}(c#{slot}, o) else #{acc} end", st}
        end)

      line = "#{subject} = #{code}\n        {o#{slot}, c#{slot + 1}} = #{tail}"
      {line, "o#{slot}", state, slot + 1}
    else
      _ -> fallback(state, slot, node)
    end
  end

  # `gas_renders_nothing?/0` lets a tag be dropped entirely instead of interpreted.
  defp renders_nothing?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :gas_renders_nothing?, 0) and
      module.gas_renders_nothing?()
  end

  defp renders_nothing?(_node), do: false

  # `gas_assigns_nothing?/0` keeps bindings alive across a node left interpreted.
  defp assigns_nothing?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :gas_assigns_nothing?, 0) and
      module.gas_assigns_nothing?()
  end

  defp assigns_nothing?(_node), do: false

  defp emit_object(node, argument, filters, state, slot) do
    case expression(argument, filters, "c#{slot}", state) do
      {:ok, code, state} -> {"", "str(#{code})", state, slot}
      :error -> fallback(state, slot, node)
    end
  end

  defp emit_for(node, key, state, slot) do
    with {:ok, enum_code, state} <- expression(node.enumerable, [], "c#{slot}", state),
         {:ok, offset_code, state} <- loop_parameter(node.parameters[:offset], "c#{slot}", state),
         {:ok, limit_code, state} <- loop_parameter(node.parameters[:limit], "c#{slot}", state) do
      # The body runs repeatedly, so anything it rebinds cannot stay folded from before.
      outer = state.known
      {body_fun, state} = conditional_body(List.wrap(node.body), loop_known(state, node.body))
      state = loop_known(%{state | known: outer}, node.body)
      {else_fun, state} = conditional_body(List.wrap(node.else_body), state)
      for_name = "#{key}-#{node.enumerable}"
      controls? = loop_control?(node.body)

      put_forloop =
        if key == "forloop" do
          ""
        else
          "\n                      cc = iter_put(cc, \"forloop\", " <>
            "forloop(idx, len#{slot}, fl#{slot}, #{literal(for_name)}))"
        end

      step =
        if controls? do
          """
          try do
                            {out, cc} = #{body_fun}(cc, o)
                            {cc, [acc, out]}
                          catch
                            {:break_exp, r, c} -> throw({:gas_cg_break, [acc, r], c})
                            {:continue_exp, r, c} -> {c, [acc, r]}
                          end\
          """
        else
          """
          {out, cc} = #{body_fun}(cc, o)
                          {cc, [acc, out]}\
          """
        end

      reduce =
        """
        list#{slot}
                      |> Enum.with_index(0)
                      |> Enum.reduce({ctx#{slot}, []}, fn {el, idx}, {cc, acc} ->
                        cc = iter_put(cc, #{literal(key)}, el)#{put_forloop}
                        #{step}
                      end)\
        """

      reduce_code =
        if controls? do
          """
          try do
                        #{reduce}
                      catch
                        {:gas_cg_break, acc, c} -> {c, acc}
                      end\
          """
        else
          reduce
        end

      loop = """
      fl#{slot} = Map.get(ctx#{slot}.iteration_vars, "forloop")

                    {done#{slot}, acc#{slot}} = #{reduce_code}

                    {acc#{slot}, iter_cleanup(done#{slot}, #{literal(key)}, fl#{slot})}\
      """

      line = """
      {o#{slot}, c#{slot + 1}} =
                case for_prepare(enumerate(#{enum_code}), #{offset_code}, #{limit_code}, #{node.reversed == true}, c#{slot}, #{literal(for_name)}) do
                  {:ok, [], ctx#{slot}} ->
                    #{else_fun}(ctx#{slot}, o)

                  {:ok, list#{slot}, ctx#{slot}} ->
                    len#{slot} = length(list#{slot})
                    #{loop}

                  {:error, msg#{slot}} ->
                    for_error(msg#{slot}, #{literal(node.loc)}, c#{slot})
                end\
      """

      {line, "o#{slot}", state, slot + 1}
    else
      _ -> fallback(state, slot, node)
    end
  end

  @unroll_limit 64

  # A loop over a fixed collection unrolls, binding the loop variable as known.
  defp unroll_for(node, key, state, slot) do
    with false <- loop_control?(node.body),
         true <- node.parameters in [nil, %{}, []],
         {:ok, list} <- const_enumerable(node.enumerable, state.known),
         true <- length(list) <= @unroll_limit do
      list = if node.reversed == true, do: Enum.reverse(list), else: list
      for_name = "#{key}-#{node.enumerable}"
      length = length(list)
      outer = state.known

      {steps, outs, state, last} =
        list
        |> Enum.with_index(0)
        |> Enum.reduce({[], [], state, "cu#{slot}"}, fn {element, index},
                                                        {steps, outs, st, ctx} ->
          bound = bind_iteration(st.known, key, element, index, length, for_name)

          {fun, st} = body(List.wrap(node.body), %{st | known: bound})
          next = "cu#{slot}_#{index}"

          bind =
            if key == "forloop" do
              "iter_put(#{ctx}, #{literal(key)}, #{literal(element)})"
            else
              "iter_put(iter_put(#{ctx}, #{literal(key)}, #{literal(element)}), \"forloop\", " <>
                "#{literal(forloop_map(index, length, for_name))})"
            end

          case st.const_bodies[fun] do
            nil ->
              step = "{ou#{slot}_#{index}, #{next}} = #{fun}(#{bind}, o)"
              {[step | steps], ["ou#{slot}_#{index}" | outs], st, next}

            literal ->
              {steps, [literal | outs], st, ctx}
          end
        end)

      state = %{state | known: outer}
      {else_fun, state} = conditional_body(List.wrap(node.else_body), state)

      body_lines =
        if list == [] do
          "{o#{slot}, c#{slot + 1}} = #{else_fun}(cu#{slot}, o)"
        else
          Enum.join(Enum.reverse(steps), "\n        ") <>
            "\n        {o#{slot}, c#{slot + 1}} = {[#{Enum.join(Enum.reverse(outs), ", ")}], " <>
            "iter_cleanup(#{last}, #{literal(key)}, fp#{slot})}"
        end

      # An empty list renders the else body, which never restores the outer loop.
      saved_forloop =
        if list == [],
          do: "",
          else: "fp#{slot} = Map.get(c#{slot}.iteration_vars, \"forloop\")\n        "

      line =
        saved_forloop <>
          "cu#{slot} = register(c#{slot}, #{literal(for_name)}, #{length} + 1)\n        " <>
          body_lines

      {:ok, line, "o#{slot}", state, slot + 1}
    else
      _ -> :error
    end
  end

  defp bind_iteration(known, "forloop", element, _index, _length, _name),
    do: Map.put(known, "forloop", element)

  defp bind_iteration(known, key, element, index, length, name) do
    known
    |> Map.put(key, element)
    |> Map.put("forloop", forloop_map(index, length, name))
  end

  defp forloop_map(index, length, name) do
    %{
      "index" => index + 1,
      "index0" => index,
      "rindex" => length - index,
      "rindex0" => length - index - 1,
      "first" => index == 0,
      "last" => length == index + 1,
      "length" => length,
      "parentloop" => nil,
      "name" => name
    }
  end

  defp const_enumerable(argument, known) do
    case const_value(argument, known) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, map} when is_map(map) and not is_struct(map) -> {:ok, Enum.to_list(map)}
      _other -> :error
    end
  end

  defp emit_if(node, kind, state, slot) do
    with {:ok, test} <- condition(node.condition, "c#{slot}", state.known),
         {:ok, chain} <- elsif_chain(node.elsifs, "c#{slot}", state.known) do
      {then_fun, state} = conditional_body(List.wrap(node.body), state)
      {else_fun, state} = conditional_body(List.wrap(node.else_body), state)

      {tail, state} =
        chain
        |> Enum.reverse()
        |> Enum.reduce({"#{else_fun}(c#{slot}, o)", state}, fn {test_code, branch}, {acc, st} ->
          {fun, st} = conditional_body(List.wrap(branch), st)
          {"if #{test_code} do #{fun}(c#{slot}, o) else #{acc} end", st}
        end)

      test = if kind == :if, do: test, else: "!(#{test})"

      line =
        "{o#{slot}, c#{slot + 1}} = if #{test} do #{then_fun}(c#{slot}, o) else #{tail} end"

      {line, "o#{slot}", state, slot + 1}
    else
      _ -> fallback(state, slot, node)
    end
  end

  defp emit_render(node, state, slot) do
    # `for` iteration compiles only with a known callee, else the tag stays interpreted.
    with {:ok, name, state} <- value(node.template, "c#{slot}", state),
         {:ok, vars, state} when is_binary(vars) <- render_vars(node, "c#{slot}", state) do
      line =
        "{o#{slot}, c#{slot + 1}} = " <>
          "render_partial(#{name}, #{vars}, c#{slot}, o, #{literal(node.loc)})"

      {line, "o#{slot}", state, slot + 1}
    else
      _ -> fallback(state, slot, node)
    end
  end

  # A fixed `{% render %}` target compiles the callee with the caller's constants bound.
  defp inline_render(node, state, slot) do
    with true <- state.known != %{},
         {:ok, name} <- const_value(node.template, state.known),
         true <- is_binary(name),
         {:ok, vars_code, state} <- render_vars(node, "c#{slot}", state),
         {:ok, bound} <- const_render_args(node, state.known),
         {:ok, tree} <- load_template(name, state.opts),
         # A callee holding break/continue gets its own module rather than inlining.
         false <- loop_control?(tree) do
      {:ok, module} = compile_cached(tree, bound, state.opts)

      case {vars_code, constant_output(module)} do
        # a `for` render repeats its callee, so a constant body still varies in count
        {{:each, name, source}, _} ->
          line =
            "{o#{slot}, c#{slot + 1}} = " <>
              "render_each(#{inspect(module)}, #{source}, #{literal(name)}, c#{slot}, o)"

          {:ok, line, "o#{slot}", state, slot + 1}

        {vars, nil} ->
          line =
            "{o#{slot}, c#{slot + 1}} = render_module(#{inspect(module)}, #{vars}, c#{slot}, o)"

          {:ok, line, "o#{slot}", state, slot + 1}

        {_vars, constant} ->
          {:ok, "", literal(constant), state, slot}
      end
    else
      _ -> :error
    end
  end

  defp load_template(name, opts) do
    if Keyword.has_key?(opts, :file_system), do: do_load(name, opts), else: :error
  end

  defp do_load(name, opts) do
    case Gas.precompile(name, Keyword.delete(opts, :codegen)) do
      {:ok, {_name, %Gas.Template{parsed_template: tree}}} -> {:ok, tree}
      {:ok, %Gas.Template{parsed_template: tree}} -> {:ok, tree}
      _other -> :error
    end
  end

  # Only arguments fixed now become known in the callee; the rest stay runtime vars.
  defp const_render_args(%{arguments: arguments}, known) when is_map(arguments) do
    bound =
      Enum.reduce(arguments, %{}, fn {key, argument}, acc ->
        case {String.contains?(key, "."), const_value(argument, known)} do
          {false, {:ok, value}} -> Map.put(acc, key, value)
          _other -> acc
        end
      end)

    {:ok, bound}
  end

  defp const_render_args(%{arguments: {:with, {source, destination}}}, known) do
    with name when is_binary(name) <- destination_name(destination),
         {:ok, value} <- const_value(source, known) do
      {:ok, %{name => value}}
    else
      _ -> {:ok, %{}}
    end
  end

  defp const_render_args(_node, _known), do: {:ok, %{}}

  # Conditions over known bindings decide now; branches not taken are never emitted.
  defp fold_chain([], _known), do: {:taken, []}
  defp fold_chain([{:else, branch} | _rest], _known), do: {:taken, branch}

  defp fold_chain([{test, branch} | rest], known) do
    case const_condition(test, known) do
      {:ok, true} -> {:taken, branch}
      {:ok, false} -> fold_chain(rest, known)
      :unknown -> :unknown
    end
  end

  # A `case` over a constant subject picks its branch here, emitting no comparison.
  defp fold_case(node, known) do
    with {:ok, subject} <- const_expression(node.argument, [], known) do
      whens = for {arguments, branch} <- node.cases, arguments != :else, do: {arguments, branch}
      else_branch = node.cases |> Enum.filter(&match?({:else, _}, &1)) |> List.last()

      fold_whens(whens, subject, else_branch, known)
    end
  end

  defp fold_whens([], _subject, else_branch, _known), do: {:taken, case_body(else_branch)}

  defp fold_whens([{arguments, branch} | rest], subject, else_branch, known) do
    case when_matches(List.wrap(arguments), subject, known) do
      {:ok, true} -> {:taken, branch}
      {:ok, false} -> fold_whens(rest, subject, else_branch, known)
      :unknown -> :unknown
    end
  end

  defp when_matches(arguments, subject, known) do
    Enum.reduce_while(arguments, {:ok, false}, fn argument, _acc ->
      with {:ok, value} <- const_value(argument, known),
           {:ok, equal?} <- const_equal(subject, value) do
        if equal?, do: {:halt, {:ok, true}}, else: {:cont, {:ok, false}}
      else
        _ -> {:halt, :unknown}
      end
    end)
  end

  # Mirrors the generated `compare/3` for `:==`; anything unsettled stays runtime.
  defp const_equal(left, right) when is_binary(left) and is_binary(right),
    do: {:ok, left == right}

  defp const_equal(left, right) do
    case Gas.BinaryCondition.eval({left, :==, right}) do
      {:ok, result} when is_boolean(result) -> {:ok, result}
      _other -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp const_condition({:negate, test}, known) do
    case const_condition(test, known) do
      {:ok, value} -> {:ok, not value}
      :unknown -> :unknown
    end
  end

  defp const_condition(%Gas.UnaryCondition{child_condition: nil} = test, known) do
    case const_expression(test.argument, test.argument_filters, known) do
      {:ok, value} -> {:ok, value not in [nil, false]}
      :unknown -> :unknown
    end
  end

  defp const_condition(%Gas.BinaryCondition{child_condition: nil} = test, known) do
    with true <- test.operator in @operators,
         {:ok, left} <- const_expression(test.left_argument, test.left_argument_filters, known),
         {:ok, right} <- const_expression(test.right_argument, test.right_argument_filters, known),
         {:ok, result} <- Gas.BinaryCondition.eval({left, test.operator, right}) do
      {:ok, result}
    else
      _ -> :unknown
    end
  end

  defp const_condition(%mod{child_condition: {joiner, child}} = test, known)
       when mod in [Gas.BinaryCondition, Gas.UnaryCondition] and joiner in [:and, :or] do
    with {:ok, left} <- const_condition(%{test | child_condition: nil}, known),
         {:ok, right} <- const_condition(child, known) do
      {:ok, if(joiner == :and, do: left and right, else: left or right)}
    else
      _ -> :unknown
    end
  end

  defp const_condition(_test, _known), do: :unknown

  defp const_value(%Literal{value: value, interp_ast: nil}, _known), do: {:ok, value}

  defp const_value(%Variable{} = variable, known) do
    case static_keys(variable) do
      nil -> resolve_known(known, const_keys(variable, known))
      keys -> resolve_known(known, keys)
    end
  end

  defp const_value(_argument, _known), do: :unknown

  # `block.blocks[key]` is fixed once `key` is.
  defp const_keys(%Variable{identifier: identifier, accesses: accesses}, known) do
    keys =
      Enum.reduce_while(List.wrap(accesses), [], fn
        %Gas.AccessLiteral{value: value}, acc when is_binary(value) or is_integer(value) ->
          {:cont, acc ++ [value]}

        %Gas.AccessVariable{variable: variable}, acc ->
          case const_value(variable, known) do
            {:ok, value} -> {:cont, acc ++ [value]}
            :unknown -> {:halt, :unknown}
          end

        _other, _acc ->
          {:halt, :unknown}
      end)

    cond do
      keys == :unknown -> :unknown
      is_binary(identifier) -> [identifier | keys]
      keys != [] -> keys
      true -> :unknown
    end
  end

  # `offset: continue` is a keyword, not a variable read.
  defp loop_parameter(nil, _ctx, state), do: {:ok, "nil", state}

  defp loop_parameter(%Variable{identifier: "continue", accesses: []}, _ctx, state),
    do: {:ok, ":continue", state}

  defp loop_parameter(argument, ctx, state), do: value(argument, ctx, state)

  defp loop_control?(%Gas.Tags.BreakTag{}), do: true
  defp loop_control?(%Gas.Tags.ContinueTag{}), do: true
  defp loop_control?(list) when is_list(list), do: Enum.any?(list, &loop_control?/1)

  defp loop_control?(%{__struct__: _} = struct),
    do: struct |> Map.from_struct() |> Map.values() |> Enum.any?(&loop_control?/1)

  defp loop_control?(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.any?(&loop_control?/1)

  defp loop_control?(map) when is_map(map), do: map |> Map.values() |> Enum.any?(&loop_control?/1)
  defp loop_control?(_), do: false

  # `for:` iteration keeps its interpreter path.
  defp render_vars(%{arguments: arguments}, ctx, state) when is_map(arguments) do
    {dotted, plain} = Enum.split_with(arguments, fn {key, _} -> String.contains?(key, ".") end)

    with {:ok, plain_code, state} <- var_map(plain, ctx, state),
         {:ok, dotted_code, state} <- dotted_map(dotted, ctx, state) do
      case dotted_code do
        nil -> {:ok, plain_code, state}
        code -> {:ok, "Map.merge(#{plain_code}, #{code})", state}
      end
    end
  end

  defp render_vars(%{arguments: {:with, {source, destination}}}, ctx, state) do
    with name when is_binary(name) <- destination_name(destination),
         {:ok, code, state} <- value(source, ctx, state) do
      {:ok, "%{#{literal(name)} => #{code}}", state}
    else
      _ -> :error
    end
  end

  defp render_vars(%{arguments: {:for, {source, destination}}}, ctx, state) do
    with name when is_binary(name) <- destination_name(destination),
         {:ok, code, state} <- value(source, ctx, state) do
      {:ok, {:each, name, code}, state}
    else
      _ -> :error
    end
  end

  defp render_vars(_node, _ctx, _state), do: :error

  defp destination_name(name) when is_binary(name), do: name
  defp destination_name(%Literal{value: value}) when is_binary(value), do: value
  defp destination_name(_other), do: nil

  defp var_map(pairs, ctx, state) do
    codes =
      Enum.reduce_while(pairs, {:ok, [], state}, fn {key, argument}, {:ok, acc, st} ->
        case value(argument, ctx, st) do
          {:ok, code, st} -> {:cont, {:ok, acc ++ ["#{literal(key)} => #{code}"], st}}
          :error -> {:halt, :error}
        end
      end)

    case codes do
      {:ok, codes, state} -> {:ok, "%{#{Enum.join(codes, ", ")}}", state}
      :error -> :error
    end
  end

  # `context.item: x` merges leaves onto whatever `context` already holds.
  defp dotted_map([], _ctx, state), do: {:ok, nil, state}

  defp dotted_map(pairs, ctx, state) do
    case Enum.reduce_while(pairs, {:ok, %{}, state}, &group_leaf(&1, &2, ctx)) do
      {:ok, grouped, state} ->
        {:ok, "%{#{Enum.map_join(grouped, ", ", &head_code(&1, ctx))}}", state}

      :error ->
        :error
    end
  end

  defp group_leaf({key, argument}, {:ok, acc, state}, ctx) do
    with [head, leaf] <- String.split(key, "."),
         {:ok, code, state} <- value(argument, ctx, state) do
      {:cont, {:ok, Map.update(acc, head, [{leaf, code}], &(&1 ++ [{leaf, code}])), state}}
    else
      _ -> {:halt, :error}
    end
  end

  defp head_code({head, leaves}, ctx) do
    leaf_code = Enum.map_join(leaves, ", ", fn {leaf, code} -> "#{literal(leaf)} => #{code}" end)

    "#{literal(head)} => Map.merge(head_map(get(#{ctx}, [#{literal(head)}], o)), %{#{leaf_code}})"
  end

  defp case_body({:else, branch}), do: branch
  defp case_body(nil), do: []

  # A `when` matches if any of its arguments equals the already-bound subject.
  defp case_clauses(whens, subject, ctx, state) do
    Enum.reduce_while(whens, {:ok, [], state}, fn {arguments, branch}, {:ok, acc, st} ->
      case when_tests(arguments, subject, ctx, st) do
        {:ok, [], st} -> {:cont, {:ok, acc ++ [{"false", branch}], st}}
        {:ok, codes, st} -> {:cont, {:ok, acc ++ [{Enum.join(codes, " or "), branch}], st}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp when_tests(arguments, subject, ctx, state) do
    Enum.reduce_while(List.wrap(arguments), {:ok, [], state}, fn argument, {:ok, codes, st} ->
      case value(argument, ctx, st) do
        {:ok, code, st} -> {:cont, {:ok, codes ++ ["compare(#{subject}, :==, #{code})"], st}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp elsif_chain(elsifs, ctx, known) do
    Enum.reduce_while(List.wrap(elsifs), {:ok, []}, fn {test, branch}, {:ok, acc} ->
      case condition(test, ctx, known) do
        {:ok, code} -> {:cont, {:ok, acc ++ [{code, branch}]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # ---- expressions -------------------------------------------------------
  defp expression(argument, filters, ctx, state) do
    case value(argument, ctx, state) do
      {:ok, base, state} -> filter_chain(base, filters, ctx, state)
      :error -> :error
    end
  end

  defp value(%Literal{value: value, interp_ast: nil}, _ctx, state),
    do: {:ok, literal(value), state}

  defp value(%Literal{interp_ast: %Gas.Template{parsed_template: sub}}, ctx, state) do
    {fun, state} = body(List.wrap(sub), state)
    {:ok, "IO.iodata_to_binary(elem(#{fun}(#{ctx}, o), 0))", state}
  end

  defp value(%Gas.Range{start: start, finish: finish}, ctx, state) do
    with {:ok, from, state} <- value(start, ctx, state),
         {:ok, to, state} <- value(finish, ctx, state) do
      {:ok, "range(#{from}, #{to})", state}
    end
  end

  defp value(%Variable{} = variable, ctx, state) do
    case static_keys(variable) do
      nil ->
        dynamic_path(variable, ctx, state)

      keys ->
        case resolve_known(state.known, keys) do
          {:ok, value} -> {:ok, literal(value), state}
          :unknown -> {:ok, "get(#{ctx}, #{literal(keys)}, o)", state}
        end
    end
  end

  defp value(_other, _ctx, _state), do: :error

  # A bound root settles the path: a missing key under it is nil, not unknown.
  defp resolve_known(known, [root | rest]) do
    if Map.has_key?(known, root) do
      constant(dig(Map.fetch!(known, root), rest))
    else
      :unknown
    end
  end

  defp resolve_known(_known, _keys), do: :unknown

  # A setting holding liquid is a template, not a value: what it renders varies.
  defp constant(%Gas.InterpolatedString{}), do: :unknown
  defp constant(value), do: {:ok, value}

  defp dig(value, []), do: value

  defp dig(value, [key | rest]) when is_map(value) and not is_struct(value) do
    case value do
      %{^key => found} -> dig(found, rest)
      _ when key == "size" -> dig(map_size(value), rest)
      _ -> nil
    end
  end

  defp dig(value, keys) do
    case Gas.Matcher.match(value, keys) do
      {:ok, found} -> found
      _ -> nil
    end
  end

  # `foo[bar]` — the key list is built at runtime, then walked like a static one.
  defp dynamic_path(%Variable{identifier: identifier, accesses: accesses}, ctx, state) do
    keys =
      Enum.reduce_while(List.wrap(accesses), {:ok, [], state}, fn
        %Gas.AccessLiteral{value: value}, {:ok, acc, st}
        when is_binary(value) or is_integer(value) ->
          {:cont, {:ok, acc ++ [literal(value)], st}}

        %Gas.AccessVariable{variable: variable}, {:ok, acc, st} ->
          case value(variable, ctx, st) do
            {:ok, code, st} -> {:cont, {:ok, acc ++ [code], st}}
            :error -> {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end)

    case keys do
      {:ok, codes, state} when is_binary(identifier) ->
        {:ok, "get(#{ctx}, [#{Enum.join([literal(identifier) | codes], ", ")}], o)", state}

      {:ok, [_ | _] = codes, state} ->
        {:ok, "get(#{ctx}, [#{Enum.join(codes, ", ")}], o)", state}

      _other ->
        :error
    end
  end

  # `Variable.static_keys/1` reports nil for a bare identifier, so derive them.
  defp static_keys(%Variable{static_keys: keys}) when is_list(keys), do: keys

  defp static_keys(%Variable{identifier: identifier, accesses: accesses}) do
    case literal_values(accesses, []) do
      {:ok, values} when is_binary(identifier) -> [identifier | values]
      {:ok, [_ | _] = values} -> values
      _ -> nil
    end
  end

  defp literal_values([], acc), do: {:ok, Enum.reverse(acc)}

  defp literal_values([%Gas.AccessLiteral{value: value} | rest], acc)
       when is_binary(value) or is_integer(value),
       do: literal_values(rest, [value | acc])

  defp literal_values(_other, _acc), do: :error

  defp filter_chain(code, filters, ctx, state) do
    Enum.reduce_while(List.wrap(filters), {:ok, code, state}, fn filter, {:ok, acc, st} ->
      with {:ok, args, st} <- filter_args(filter.positional_arguments, ctx, st),
           {:ok, args, st} <- append_named(args, filter.named_arguments, ctx, st),
           true <- known_filter?(filter.function, length(args) + 1) do
        {:cont,
         {:ok, "Gas.Filters.Filter.#{filter.function}(#{Enum.join([acc | args], ", ")})", st}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  # Named arguments arrive as one trailing map, as `Argument.apply_filters` builds.
  defp append_named(args, named, _ctx, state) when named in [nil, %{}], do: {:ok, args, state}

  defp append_named(args, named, ctx, state) do
    pairs =
      Enum.reduce_while(named, {:ok, [], state}, fn {key, argument}, {:ok, acc, st} ->
        case value(argument, ctx, st) do
          {:ok, code, st} -> {:cont, {:ok, acc ++ ["#{literal(key)} => #{code}"], st}}
          :error -> {:halt, :error}
        end
      end)

    case pairs do
      {:ok, codes, state} -> {:ok, args ++ ["%{#{Enum.join(codes, ", ")}}"], state}
      :error -> :error
    end
  end

  defp filter_args(args, ctx, state) do
    Enum.reduce_while(List.wrap(args), {:ok, [], state}, fn arg, {:ok, acc, st} ->
      case value(arg, ctx, st) do
        {:ok, code, st} -> {:cont, {:ok, acc ++ [code], st}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp known_filter?(name, arity), do: arity in Map.get(@filters, name, [])

  # ---- conditions --------------------------------------------------------
  defp condition(%Gas.UnaryCondition{child_condition: nil} = test, ctx, known) do
    with true <- test.argument_filters in [nil, []],
         {:ok, code} <- condition_value(test.argument, ctx, known) do
      {:ok, "truthy(#{code})"}
    else
      _ -> :error
    end
  end

  defp condition(%Gas.BinaryCondition{child_condition: nil} = test, ctx, known) do
    with true <- test.left_argument_filters in [nil, []],
         true <- test.right_argument_filters in [nil, []],
         true <- test.operator in @operators,
         {:ok, left} <- condition_value(test.left_argument, ctx, known),
         {:ok, right} <- condition_value(test.right_argument, ctx, known) do
      {:ok, "compare(#{left}, #{literal(test.operator)}, #{right})"}
    else
      _ -> :error
    end
  end

  defp condition(%mod{child_condition: {joiner, child}} = test, ctx, known)
       when mod in [Gas.BinaryCondition, Gas.UnaryCondition] and joiner in [:and, :or] do
    with {:ok, left} <- condition(%{test | child_condition: nil}, ctx, known),
         {:ok, right} <- condition(child, ctx, known) do
      {:ok, "(#{left} #{joiner} #{right})"}
    else
      _ -> :error
    end
  end

  defp condition(_other, _ctx, _known), do: :error

  # A condition has nowhere to put a helper function, so one that needs it must not compile.
  defp condition_value(argument, ctx, known) do
    case value(argument, ctx, new_state(known, [])) do
      {:ok, code, %{funs: []}} -> {:ok, code}
      _other -> :error
    end
  end

  defp new_state(known, opts),
    do: %{
      funs: [],
      data: [],
      n: 0,
      fallbacks: 0,
      nodes: 0,
      known: known,
      opts: opts,
      touched: MapSet.new(),
      const_bodies: %{}
    }

  # `inspect/1` defaults truncate, which would emit a shortened template, not fail.
  defp literal(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  # The recorded constant is Elixir source; evaluate it once so callers splice a value.
  defp constant_value(source) do
    {value, _bindings} = Code.eval_string(source)
    value
  end

  defp forget(state, name) do
    %{state | known: Map.delete(state.known, name), touched: MapSet.put(state.touched, name)}
  end

  defp rebind(state, name, :unknown), do: forget(state, name)

  defp rebind(state, name, {:ok, value}) do
    %{state | known: Map.put(state.known, name, value), touched: MapSet.put(state.touched, name)}
  end

  defp loop_known(state, nodes) do
    case body_assigns(List.wrap(nodes)) do
      :all -> %{state | known: %{}}
      names -> %{state | known: Map.drop(state.known, MapSet.to_list(names))}
    end
  end

  # Names a subtree rebinds; `:all` when it holds an interpreted node.
  defp body_assigns(nodes) when is_list(nodes) do
    Enum.reduce_while(nodes, MapSet.new(), fn node, acc ->
      case body_assigns(node) do
        :all -> {:halt, :all}
        names -> {:cont, MapSet.union(acc, names)}
      end
    end)
  end

  defp body_assigns(%AssignTag{argument: target}), do: MapSet.new([to_string(target)])

  defp body_assigns(%CaptureTag{argument: target, body: inner}) do
    case body_assigns(List.wrap(inner)) do
      :all -> :all
      names -> MapSet.put(names, to_string(target))
    end
  end

  defp body_assigns(%IfTag{} = node) do
    body_assigns(
      List.wrap(node.body) ++
        List.wrap(node.else_body) ++
        Enum.flat_map(List.wrap(node.elsifs), &List.wrap(elem(&1, 1)))
    )
  end

  defp body_assigns(%CaseTag{cases: cases}),
    do: body_assigns(Enum.flat_map(cases, &List.wrap(elem(&1, 1))))

  defp body_assigns(%ForTag{} = node),
    do: body_assigns(List.wrap(node.body) ++ List.wrap(node.else_body))

  defp body_assigns(%Text{}), do: MapSet.new()
  defp body_assigns(%Object{}), do: MapSet.new()
  defp body_assigns(%Gas.Tags.NoOpTag{}), do: MapSet.new()
  defp body_assigns(%Gas.Tags.RenderTag{}), do: MapSet.new()
  defp body_assigns(_other), do: :all

  # A body that only sometimes runs cannot leave its bindings known afterwards.
  defp conditional_body(nodes, state) do
    before = state.touched
    {fun, state} = body(nodes, %{state | touched: MapSet.new()})
    newly = state.touched

    {fun,
     %{
       state
       | known: Map.drop(state.known, MapSet.to_list(newly)),
         touched: MapSet.union(before, newly)
     }}
  end

  # Only a filter-free assign carries its value forward.
  defp const_assign(%Object{argument: argument, filters: filters}, known),
    do: const_expression(argument, filters, known)

  defp const_assign(_object, _known), do: :unknown

  # Pure filters over constant arguments are constant too, so they run once here.
  defp const_expression(argument, filters, known) do
    with {:ok, value} <- const_value(argument, known) do
      Enum.reduce_while(List.wrap(filters), {:ok, value}, fn filter, {:ok, acc} ->
        case apply_pure(filter, acc, known) do
          {:ok, result} -> {:cont, {:ok, result}}
          :unknown -> {:halt, :unknown}
        end
      end)
    end
  end

  defp apply_pure(filter, input, known) do
    with true <- filter.function in @pure_filters,
         true <- filter.named_arguments in [nil, %{}],
         {:ok, args} <- const_args(filter.positional_arguments, known),
         {:ok, result} <-
           Gas.StandardFilter.apply(filter.function, [input | args], filter.loc, []) do
      constant(result)
    else
      _ -> :unknown
    end
  rescue
    _ -> :unknown
  end

  defp const_args(arguments, known) do
    Enum.reduce_while(List.wrap(arguments), {:ok, []}, fn argument, {:ok, acc} ->
      case const_value(argument, known) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end
end
