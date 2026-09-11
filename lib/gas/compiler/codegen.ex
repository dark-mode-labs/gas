defmodule Gas.Compiler.Codegen do
  @moduledoc """
  Compiles a parsed template into an Elixir module, so rendering is a function
  call instead of an AST walk. Assigns stay a runtime map.

  A whole `Gas.Context` is threaded through the generated functions, not a bare
  map: `{% increment %}` writes `counter_vars`, `{% for %}` writes
  `iteration_vars` and `registers`, and a read resolves across all three.

  A node the compiler cannot take is emitted as a call back into the interpreter
  and travels in `@nodes`; `source/4` reports how much of a tree compiled, and a
  module with nothing to interpret carries no `@nodes` entry points at all.
  """

  alias Gas.{Literal, Object, Text, Variable}
  alias Gas.Tags.{AssignTag, CaptureTag, CaseTag, ForTag, IfTag}

  @filters Gas.Filters.Filter.__info__(:functions)
           |> Enum.map(fn {name, arity} -> {to_string(name), arity} end)
           |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

  @operators [:==, :!=, :<>, :>, :<, :>=, :<=, :contains]

  @module_limit 2_000

  # Bound at render time, never by name in the tree, so no entry extraction can see them.
  @runtime_bound ~w(forloop parentloop tablerowloop)

  @prefix "Elixir.Gas.Compiled."

  # Filters safe at compile time: deterministic, depending only on their arguments.
  @pure_filters ~w(append prepend upcase downcase capitalize strip lstrip rstrip
                   join push push_if split first last size default replace
                   replace_first remove remove_first plus minus times divided_by
                   modulo abs at_least at_most ceil floor round sort sort_natural
                   reverse uniq compact concat slice truncate truncatewords
                   escape escape_once url_encode url_decode strip_html
                   strip_newlines newline_to_br keys values to_str to_integer)

  @doc """
  The module for `tree`, compiling one unless it is already compiled.

  Nothing is cached: a tree with no name of its own is compiled into a module named after its
  content, so asking twice for the same tree reaches the same module because the name is the same.
  """
  @spec ensure_compiled(list, map, keyword) :: {:ok, module} | :error
  def ensure_compiled(tree, known \\ %{}, opts \\ []) do
    tree = List.wrap(tree)

    case compiled(tree, known, opts) do
      {:ok, module} -> {:ok, module}
      :error -> compile_new(tree, known, opts)
    end
  end

  # The module already compiled for `tree`, or `:error`; never compiles one. A `:name` in `opts`
  # answers by name: two files holding the same liquid are still two files.
  defp compiled(tree, known, opts) do
    tree = List.wrap(tree)

    case named_module(known, opts) do
      {:ok, module} -> loaded(module)
      :error -> loaded(content_name(tree, known, opts))
    end
  end

  # `module_loaded/1`, not the code server: these modules exist only because something compiled
  # them here, so there is no file to go looking for.
  defp loaded(module) when is_atom(module) do
    if :erlang.module_loaded(module), do: {:ok, module}, else: :error
  end

  defp loaded(name) when is_binary(name) do
    with {:ok, module} <- module_for(name), do: loaded(module)
  end

  @doc """
  The module for `tree`, compiling one unless the host asked to be handed misses instead.

  With `:on_codegen_miss` set, an uncompiled tree goes to the host and this answers `:deferred`:
  the caller renders interpreted now and reads the module on a later pass. The callback runs on
  the render path, so it must hand the work off rather than do it.

  A 2-arity callback is handed the options too, which carry the `:name` the module is called
  after; a 1-arity one gets only the tree, and what it compiles is named after its content.
  """
  @spec fetch_or_defer(list, map, keyword) :: {:ok, module} | :deferred | :error
  def fetch_or_defer(tree, known \\ %{}, opts \\ []) do
    tree = List.wrap(tree)

    case compiled(tree, known, opts) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        case Keyword.get(opts, :on_codegen_miss) do
          fun when is_function(fun, 2) ->
            fun.(tree, opts)
            :deferred

          fun when is_function(fun, 1) ->
            fun.(tree)
            :deferred

          nil ->
            compile_new(tree, known, opts)
        end
    end
  end

  # A named template needs no ceiling: its module is its file, and a theme holds finitely many.
  defp compile_new(tree, known, opts) do
    case named_module(known, opts) do
      {:ok, module} -> compile(tree, module, known, opts)
      :error -> compile_hashed(tree, known, opts)
    end
  end

  @doc """
  Drops the module compiled for the template named `name`, so the next compile builds it again.

  A module answers for its name, not for the liquid it was built from, so a rewritten file keeps
  the module it had until this is called. Hosts that reload templates in a running system call it
  when the file changes; a host that only ever starts fresh never needs to.
  """
  @spec forget(binary) :: :ok
  def forget(name) when is_binary(name) do
    with {:ok, module} <- module_for(name), true <- :erlang.module_loaded(module) do
      # Deleting makes the loaded version old and purging then drops it. Purging first would
      # only clear a version older than the one still holding the name.
      :code.delete(module)
      :code.purge(module)
    end

    :ok
  end

  # Only a whole template gets its path for a name: a tree compiled against bindings is one
  # caller's reading of the file, not the file.
  defp named_module(known, opts) when map_size(known) == 0 do
    case Keyword.get(opts, :name) do
      name when is_binary(name) and name != "" -> {:ok, module_name(name)}
      _other -> :error
    end
  end

  defp named_module(_known, _opts), do: :error

  # The module is the path with its separators flattened, and nothing else: a render by name asks
  # for this on every render, so splitting the path and camelising each segment would be that work
  # done per render. `defmodule` will not take an `Elixir.`-prefixed atom that is not alias-shaped,
  # which is the only reason the path is touched at all.
  defp module_name(name), do: :erlang.binary_to_atom(@prefix <> flatten(name))

  defp flatten(name), do: String.replace(name, ["/", "-", ".", " "], "_")

  @doc """
  The module the template named `name` compiled into, or `:error` if nothing ever compiled it.

  A pure function of the name — no lookup table stands between a caller and its callee — and it
  coins no atom, so asking for a name nothing compiled cannot grow the atom table.
  """
  @spec module_for(binary) :: {:ok, module} | :error
  def module_for(name) when is_binary(name) do
    {:ok, :erlang.binary_to_existing_atom(@prefix <> flatten(name))}
  rescue
    ArgumentError -> :error
  end

  # A loaded module is never purged, and liquid-bearing settings are merchant-editable.
  defp compile_hashed(tree, known, opts) do
    if compiled_count() < module_limit(opts) do
      module = module_name(content_name(tree, known, opts))

      # Checked again here: the caller looked before this, and another task may have finished the
      # same content since. Recompiling it would only redefine identical code, loudly.
      with :error <- loaded(module), do: compile_content(tree, module, known, opts)
    else
      Gas.Compiler.Runtime.log_once({__MODULE__, :limit_reported}, fn ->
        "gas: the module limit of #{module_limit(opts)} for liquid with no name of its own is " <>
          "spent; such liquid now renders interpreted"
      end)

      :error
    end
  end

  # Losing a race is not a failure, so neither it nor the compiler's own complaint about the name
  # is reported; only a wait that never ends in a module is.
  defp compile_content(tree, module, known, opts) do
    case attempt(tree, module, known, opts) do
      {{:ok, _module}, _diagnostics} = built ->
        reported(built, &redefined?(&1, module))

      {{:error, formatted}, _diagnostics} = failed ->
        with :error <- awaited(module, opts) do
          reported(failed)
          refused(module, formatted)
        end
    end
  end

  @content_prefix "c_"

  # Options the emitted code turns on, so one tree under two of them is two modules. Not `:trees`:
  # what it holds is what the file system would have given.
  @shaping_opts [:file_system, :tags, :opaque_roots, :name_modules]

  # SHA-256: liquid comes from merchant settings, and a collision renders one merchant's as another's.
  defp content_name(tree, known, opts) do
    shape = Enum.map(@shaping_opts, &Keyword.get(opts, &1))
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({tree, known, shape}))

    @content_prefix <> Base.encode16(digest, case: :lower)
  end

  @name_wait_ms 5
  @name_wait_tries 200

  # Same name means same source, so the loser waits for the winner rather than emitting a call to
  # a module that never landed. Nothing races a pass of one, which reports its failure at once.
  defp awaited(module, opts) do
    if Keyword.get(opts, :max_concurrency, 1) > 1,
      do: waited(module, @name_wait_tries),
      else: :error
  end

  defp waited(_module, 0), do: :error

  defp waited(module, tries) do
    if :erlang.module_loaded(module) do
      {:ok, module}
    else
      Process.sleep(@name_wait_ms)
      waited(module, tries - 1)
    end
  end

  # Counted off the modules themselves, so nothing holds a tally. Read per compile, never per look.
  defp compiled_count do
    prefix = @prefix <> @content_prefix

    Enum.count(:erlang.loaded(), &String.starts_with?(Atom.to_string(&1), prefix))
  end

  # How many modules liquid with no name of its own may mint; a template named after its path is
  # not counted. A parallel pass reads the count before compiling, so the ceiling is approximate.
  defp module_limit(opts) do
    Keyword.get_lazy(opts, :module_limit, fn ->
      Application.get_env(:gas, :max_compiled_modules, @module_limit)
    end)
  end

  @doc "Builds and loads a module for `tree`. Returns `{:ok, module}` or `:error`."
  @spec compile(list, module, map, keyword) :: {:ok, module} | :error
  def compile(tree, mod, known \\ %{}, opts \\ []) do
    case reported(attempt(tree, mod, known, opts)) do
      {:ok, module} -> {:ok, module}
      {:error, formatted} -> refused(mod, formatted)
    end
  end

  # The compiler prints its diagnostics before raising, so they are held here and printed by
  # whoever decides the compile actually failed.
  defp attempt(tree, mod, known, opts) do
    Code.with_diagnostics(fn -> guarded_load(tree, mod, known, opts) end)
  end

  defp guarded_load(tree, mod, known, opts) do
    {:ok, load(List.wrap(tree), mod, known, opts)}
  rescue
    error -> {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    kind, value -> {:error, Exception.format(kind, value, __STACKTRACE__)}
  end

  defp reported({result, diagnostics}, ignore \\ fn _diagnostic -> false end) do
    diagnostics |> Enum.reject(ignore) |> Enum.each(&Code.print_diagnostic/1)
    result
  end

  # A content-named module redefined is the same source by construction, so the compiler's notice
  # says nothing. Anything else it has to say about the module is still printed.
  @doc false
  def redefined?(%{severity: :warning, message: message}, module),
    do:
      String.contains?(message, "redefining module") and
        String.contains?(message, inspect(module))

  def redefined?(_diagnostic, _module), do: false

  @doc false
  def load(tree, mod, known, opts) do
    {source, _nodes, _covered, _total, _constant} = build(tree, mod, known, opts)
    [{module, _bin}] = Code.compile_string(source)
    # `Code.compile_string/1` hands the module back while it still counts as being defined, and a
    # name compiled again inside that window is refused. This waits for it to be a module.
    Code.ensure_compiled!(module)
    module
  end

  defp refused(mod, formatted) do
    Gas.Compiler.Runtime.log_once({__MODULE__, :refused, mod}, fn ->
      "gas: #{inspect(mod)} would not compile, so it renders interpreted:\n#{formatted}"
    end)

    :error
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
  # The module says so itself; nothing keeps a register of what each one renders.
  defp constant_output(module) do
    if function_exported?(module, :__gas_constant__, 0), do: module.__gas_constant__()
  end

  @doc """
  An argument's value if `known` fixes it at compile time, else `:unknown`.

  For `Gas.Tag.gas_rewrite/2` implementations deciding whether the value their
  behaviour turns on is already settled.
  """
  @spec constant_argument(term, map) :: {:ok, term} | :unknown
  def constant_argument(argument, known), do: const_value(argument, known)

  defp build(tree, mod, known, opts) do
    tree = List.wrap(tree)
    bound = bindings(tree, %{})
    aliases = aliases(tree, bound)
    groups = extract_groups(tree, aliases, bound)

    state = %{
      new_state(known, opts)
      | aliases: aliases,
        extracts: extract_table(groups),
        raw_extracts: raw_extracts(groups)
    }

    {entry, state} = body(tree, state)
    extraction = extract_source(groups)
    nodes = List.to_tuple(Enum.reverse(state.data))
    constant = state.const_bodies[entry]

    # Uncommented on purpose: what `@nodes`, `__gas_constant__` and `render/2`'s guard are for is
    # a fact about the compiler, and belongs here rather than in each module it emits.
    src = """
    defmodule #{inspect(mod)} do
      @moduledoc false
      import Gas.Compiler.Runtime, warn: false
    #{nodes_attribute(nodes)}
      def __gas_constant__, do: #{constant || "nil"}

      def render(%Gas.Context{matcher_module: Gas.Matcher, strict_variables: false} = ctx, opts) do
        if ctx.scopes == Gas.Context.default_scopes() do
          #{extraction}
          #{entry}(ctx, opts, e)
        else
          raise Gas.Compiler.Runtime.uncompiled_context(__MODULE__, ctx)
        end
      end

      def render(%Gas.Context{} = ctx, opts) do
        _ = opts
        raise Gas.Compiler.Runtime.uncompiled_context(__MODULE__, ctx)
      end

    #{state.funs |> Enum.reverse() |> live_funs(entry) |> Enum.join("\n")}
    #{node_entry_points(nodes)}
    end
    """

    {src, nodes, state.nodes - state.fallbacks, state.nodes, constant}
  end

  # A template every node of which compiled holds nothing to run, so it carries neither.
  defp nodes_attribute({}), do: ""
  defp nodes_attribute(nodes), do: "  @nodes #{literal(nodes)}\n"

  defp node_entry_points({}), do: ""

  defp node_entry_points(_nodes) do
    """
      def interpret(index, ctx, opts) do
        Gas.render([elem(@nodes, index)], ctx, opts)
      end

      def dispatch(index, ctx, opts) do
        Gas.Renderable.render(elem(@nodes, index), ctx, opts)
      end
    """
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
    outer_hoists = state.hoists
    outer_locals = state.locals
    state = %{state | n: state.n + 1, hoists: [], locals: %{}}

    {steps, state, slot} = emit_nodes(nodes, [], state, 0)

    prologue =
      Enum.map(state.hoists, fn {prefix, binding} ->
        "#{binding} = lookup(c0, #{literal(prefix)})"
      end)

    lines = prologue ++ (steps |> Enum.map(& &1.line) |> Enum.reject(&(&1 == "")))
    outs = Enum.map(steps, &{&1.out, &1.const?})
    merged = merge_constants(outs)

    expression = "[#{Enum.join(merged, ", ")}]"

    state =
      cond do
        lines == [] and Enum.all?(outs, &elem(&1, 1)) ->
          constant = if merged == [], do: ~s(""), else: Enum.join(merged, " <> ")
          %{state | const_bodies: Map.put(state.const_bodies, name, constant)}

        lines == [] and slot == 0 and not Regex.match?(~r/\bc\d+\b/, expression) ->
          %{state | pure_bodies: Map.put(state.pure_bodies, name, expression)}

        true ->
          state
      end

    fun =
      if Enum.any?(steps, & &1.throws?) do
        incremental_body(name, steps, "c#{slot}", prologue)
      else
        """
          defp #{name}(c0, o, e) do
            _ = o
            _ = e
            #{Enum.join(lines, "\n        ")}
            {[#{Enum.join(merged, ", ")}], c#{slot}}
          end
        """
      end

    {name, %{state | funs: [fun | state.funs], hoists: outer_hoists, locals: outer_locals}}
  end

  defp emit_capture(inner, name, state, slot) do
    {fun, state} = body(List.wrap(inner), state)
    state = forget(state, name)
    local = "v#{slot}"

    line =
      "{cap#{slot}, cc#{slot}} = #{fun}(c#{slot}, o, e); #{local} = IO.iodata_to_binary(cap#{slot}); " <>
        "c#{slot + 1} = put_var(cc#{slot}, #{literal(name)}, #{local})"

    kept =
      case body_assigns(List.wrap(inner)) do
        :all -> %{}
        names -> Map.drop(state.locals, MapSet.to_list(names))
      end

    {line, "[]", %{state | locals: Map.put(kept, name, local)}, slot + 1}
  end

  defp emit_nodes([], steps, state, slot), do: {Enum.reverse(steps), state, slot}

  defp emit_nodes([node | rest], steps, state, slot) do
    case settled_branch(node, state) do
      {:ok, branch} ->
        emit_nodes(branch ++ rest, steps, state, slot)

      :error ->
        state = %{state | nodes: state.nodes + 1, locals: kept_locals(node, state.locals)}
        {line, out, state, next} = emit(node, state, slot)
        state = %{state | locals: kept_locals(node, state.locals)}

        step = %{
          line: line,
          out: out,
          const?: constant_out?(line, out),
          throws?: loop_control?(node),
          ctx: "c#{next}"
        }

        emit_nodes(rest, [step | steps], state, next)
    end
  end

  # A condition the bindings settle contributes its branch to this body rather than a function of
  # its own, so what the branch assigns keeps folding into the nodes that follow it.
  defp settled_branch(%IfTag{tag_name: kind} = node, state) when kind in [:if, :unless] do
    first = if kind == :if, do: node.condition, else: {:negate, node.condition}
    chain = [{first, node.body} | List.wrap(node.elsifs)] ++ [{:else, node.else_body}]

    case fold_chain(chain, state.known) do
      {:taken, branch} -> {:ok, List.wrap(branch)}
      :unknown -> :error
    end
  end

  defp settled_branch(%CaseTag{} = node, state) do
    case fold_case(node, state.known) do
      {:taken, branch} -> {:ok, List.wrap(branch)}
      :unknown -> :error
    end
  end

  defp settled_branch(_node, _state), do: :error

  # `break`/`continue` carry prior output, so a throwing body hands its accumulator on.
  defp incremental_body(name, steps, exit_ctx, prologue) do
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
      defp #{name}(c0, o, e) do
        _ = o
        _ = e
        #{Enum.join(prologue, "\n        ")}
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
  # A node that rendered nothing contributes nothing: keeping its `[]` only lengthens the
  # iolist the caller walks, and an empty literal folds into the constant beside it.
  # Steps that render nothing are dropped before the constants are grouped, so an `{% assign %}`
  # between two pieces of static text cannot leave them in separate cells of the output list.
  defp merge_constants(outs) do
    outs
    |> Enum.reject(fn {out, _const?} -> out in ["[]", ~s("")] end)
    |> Enum.chunk_by(&elem(&1, 1))
    |> Enum.flat_map(&merge_chunk/1)
    |> Enum.reject(&(&1 in ["[]", ~s("")]))
  end

  defp merge_chunk([{_out, false} | _] = chunk), do: Enum.map(chunk, &elem(&1, 0))

  defp merge_chunk(chunk) do
    case Enum.reject(chunk, &(elem(&1, 0) == "[]")) do
      [] ->
        []

      # `<>` rather than one merged literal: the BEAM compiler folds both to the same
      # `{:literal, ...}`, so reading the sources back to merge them here buys nothing.
      kept ->
        [Enum.map_join(kept, " <> ", &literal_source/1)]
    end
  end

  defp literal_source({out, _}), do: out

  defp fallback(state, slot, node) do
    {index, state} = stored(state, node)
    state = %{state | fallbacks: state.fallbacks + 1}

    {"{o#{slot}, c#{slot + 1}} = interpret(#{index}, c#{slot}, o)", "o#{slot}", state, slot + 1}
  end

  # A tag reading what only the request supplies still renders one fixed way, so the call is
  # emitted and the value left to run time. That is a compiled node, not an interpreted one.
  defp emit_at_runtime(state, slot, node) do
    {index, state} = stored(state, node)

    {"{o#{slot}, c#{slot + 1}} = dispatch(#{index}, c#{slot}, o)", "o#{slot}", state, slot + 1}
  end

  # An interpreted node may assign anything, so bindings survive only if it says not.
  defp stored(state, node) do
    known = if assigns_nothing?(node), do: state.known, else: %{}

    {length(state.data), %{state | data: [node | state.data], known: known}}
  end

  # ---- emit --------------------------------------------------------------
  defp emit(%Text{text: text}, state, slot), do: {"", literal(text), state, slot}

  defp emit(%Gas.Tags.NoOpTag{}, state, slot), do: {"", "[]", state, slot}

  # The loop catches what the interpreter throws, so leaving the loop is the same throw either way.
  defp emit(%Gas.Tags.BreakTag{}, state, slot),
    do: {"throw({:break_exp, [], c#{slot}})", "[]", state, slot}

  defp emit(%Gas.Tags.ContinueTag{}, state, slot),
    do: {"throw({:continue_exp, [], c#{slot}})", "[]", state, slot}

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
        local = "v#{slot}"
        state = %{state | locals: Map.put(state.locals, name, local)}

        {"#{local} = #{code}\n        c#{slot + 1} = put_var(c#{slot}, #{literal(name)}, #{local})",
         "[]", state, slot + 1}

      :error ->
        fallback(state, slot, node)
    end
  end

  defp emit(%CaptureTag{argument: target, body: inner}, state, slot) do
    name = to_string(target)

    case const_nodes(List.wrap(inner), state.known) do
      # Themes build class fragments by capturing them; a captured body the bindings settle is a
      # string, and leaving it unfolded stops the accumulation that follows from folding at all.
      {:ok, captured} ->
        {"", "[]", rebind(state, name, {:ok, captured}), slot}

      :unknown ->
        emit_capture(inner, name, state, slot)
    end
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
        {:ok, replacement} ->
          emit_rewritten(replacement, state, slot)

        :error ->
          if renders_at_runtime?(node),
            do: emit_at_runtime(state, slot, node),
            else: fallback(state, slot, node)
      end
    end
  end

  # A body whose whole output is fixed, or which touches no context, is inlined at the call site.
  defp emit_body(fun, state, slot) do
    cond do
      literal = state.const_bodies[fun] ->
        {"", literal, state, slot}

      expression = state.pure_bodies[fun] ->
        {"", expression, state, slot}

      true ->
        {"{o#{slot}, c#{slot + 1}} = #{fun}(c#{slot}, o, e)", "o#{slot}", state, slot + 1}
    end
  end

  # A call to a body, or the body itself where it needs no context to run.
  defp branch(fun, ctx, state) do
    case state.pure_bodies[fun] do
      nil -> "#{fun}(#{ctx}, o, e)"
      expression -> "{#{expression}, #{ctx}}"
    end
  end

  # A rewritten tag contributes output only, so its context changes are discarded.
  defp emit_rewritten(replacement, state, slot) do
    {fun, state} = body(List.wrap(replacement), state)

    case state.const_bodies[fun] do
      nil ->
        line = "{o#{slot}, _} = #{fun}(c#{slot}, o, e)\n        c#{slot + 1} = c#{slot}"
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
        |> Enum.reduce({branch(else_fun, "c#{slot}", state), state}, fn {test, branch},
                                                                        {acc, st} ->
          {fun, st} = conditional_body(List.wrap(branch), st)
          {"if #{test} do #{fun}(c#{slot}, o, e) else #{acc} end", st}
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

  # `gas_renders_at_runtime?/0` lets a tag be called rather than interpreted when nothing the
  # compiler knows could have rewritten it.
  defp renders_at_runtime?(%module{}) do
    Code.ensure_loaded?(module) and function_exported?(module, :gas_renders_at_runtime?, 0) and
      module.gas_renders_at_runtime?()
  end

  defp renders_at_runtime?(_node), do: false

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
                            {out, cc} = #{body_fun}(cc, o, e)
                            {cc, [acc, out]}
                          catch
                            {:break_exp, r, c} -> throw({:gas_cg_break, [acc, r], c})
                            {:continue_exp, r, c} -> {c, [acc, r]}
                          end\
          """
        else
          """
          {out, cc} = #{body_fun}(cc, o, e)
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
                    #{else_fun}(ctx#{slot}, o, e)

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
              step = "{ou#{slot}_#{index}, #{next}} = #{fun}(#{bind}, o, e)"
              {[step | steps], ["ou#{slot}_#{index}" | outs], st, next}

            literal ->
              {steps, [literal | outs], st, ctx}
          end
        end)

      state = %{state | known: leave_loop(state.known, outer, key)}
      {else_fun, state} = conditional_body(List.wrap(node.else_body), state)

      body_lines =
        if list == [] do
          "{o#{slot}, c#{slot + 1}} = #{else_fun}(cu#{slot}, o, e)"
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

  # Only the loop's own names go out of scope with it: what the body assigned outlives the loop,
  # which is how a list built one element at a time survives to be read after it.
  defp leave_loop(inner, outer, key) do
    Enum.reduce([key, "forloop"], Map.drop(inner, [key, "forloop"]), fn name, acc ->
      case Map.fetch(outer, name) do
        {:ok, value} -> Map.put(acc, name, value)
        :error -> acc
      end
    end)
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

  defp kept_locals(%AssignTag{}, locals), do: locals
  defp kept_locals(%Gas.Text{}, locals), do: locals
  defp kept_locals(%Object{}, locals), do: locals
  defp kept_locals(%CaptureTag{}, locals), do: locals
  defp kept_locals(%IfTag{} = node, locals), do: if(lone_assign_pair(node), do: locals, else: %{})
  defp kept_locals(_node, _locals), do: %{}

  defp lone_assign_pair(node) do
    with [] <- List.wrap(node.elsifs),
         {:ok, then_name, _} <- lone_assign(List.wrap(node.body)),
         {:ok, else_name, _} <- lone_assign(List.wrap(node.else_body)),
         {:ok, _name} <- same_target(then_name, else_name) do
      true
    else
      _ -> false
    end
  end

  defp emit_if(node, kind, state, slot) do
    case settled_assign(node, kind, state, slot) do
      {:ok, line, out, state, next} -> {line, out, state, next}
      :error -> emit_branches(node, kind, state, slot)
    end
  end

  # A branch that only assigns needs no function of its own: the two values are the arms of one
  # expression, which keeps the assign a value rather than a context another body hands back.
  defp settled_assign(node, kind, state, slot) do
    with [] <- List.wrap(node.elsifs),
         {:ok, then_name, then_value} <- lone_assign(List.wrap(node.body)),
         {:ok, else_name, else_value} <- lone_assign(List.wrap(node.else_body)),
         {:ok, name} <- same_target(then_name, else_name),
         {:ok, test} <- condition(node.condition, "c#{slot}", state),
         {:ok, line, state} <-
           assign_if(test, kind, name, then_value, else_value, state, slot) do
      {:ok, line, "[]", forget(state, name), slot + 1}
    else
      _ -> :error
    end
  end

  defp same_target(:any, :any), do: :error
  defp same_target(:any, name), do: {:ok, name}
  defp same_target(name, :any), do: {:ok, name}
  defp same_target(name, name), do: {:ok, name}
  defp same_target(_a, _b), do: :error

  # `nil` stands for the branch that leaves the variable as it was.
  defp lone_assign([]), do: {:ok, :any, nil}

  defp lone_assign([%AssignTag{argument: target, object: %Object{} = obj}]),
    do: {:ok, to_string(target), obj}

  defp lone_assign(_nodes), do: :error

  # With the value already in hand the arms are values, and the branch that assigns nothing
  # hands back the one it had. Without it they are contexts, so the idle branch stays idle
  # rather than reading a variable out to write the same value straight back in.
  defp assign_if(test, kind, name, then_value, else_value, state, slot) do
    ctx = "c#{slot}"
    test = if kind == :if, do: test, else: "!(#{test})"
    held = state.locals[name]

    with {:ok, then_arm, state} <- assign_arm(then_value, name, held, ctx, state),
         {:ok, else_arm, state} <- assign_arm(else_value, name, held, ctx, state) do
      if held do
        local = "v#{slot}"

        {:ok,
         "#{local} = if #{test} do #{then_arm} else #{else_arm} end\n        " <>
           "c#{slot + 1} = put_var(#{ctx}, #{literal(name)}, #{local})",
         %{state | locals: Map.put(state.locals, name, local)}}
      else
        {:ok, "c#{slot + 1} = if #{test} do #{then_arm} else #{else_arm} end",
         %{state | locals: Map.delete(state.locals, name)}}
      end
    end
  end

  defp assign_arm(nil, _name, held, ctx, state), do: {:ok, held || ctx, state}

  defp assign_arm(%Object{} = obj, name, held, ctx, state) do
    with {:ok, code, state} <- expression(obj.argument, obj.filters, ctx, state) do
      {:ok, if(held, do: code, else: "put_var(#{ctx}, #{literal(name)}, #{code})"), state}
    end
  end

  defp emit_branches(node, kind, state, slot) do
    with {:ok, test} <- condition(node.condition, "c#{slot}", state),
         {:ok, chain} <- elsif_chain(node.elsifs, "c#{slot}", state) do
      {then_fun, state} = conditional_body(List.wrap(node.body), state)
      {else_fun, state} = conditional_body(List.wrap(node.else_body), state)

      {tail, state} =
        chain
        |> Enum.reverse()
        |> Enum.reduce({branch(else_fun, "c#{slot}", state), state}, fn {test_code, branch},
                                                                        {acc, st} ->
          {fun, st} = conditional_body(List.wrap(branch), st)
          {"if #{test_code} do #{branch(fun, "c#{slot}", st)} else #{acc} end", st}
        end)

      test = if kind == :if, do: test, else: "!(#{test})"

      line =
        "{o#{slot}, c#{slot + 1}} = if #{test} do #{branch(then_fun, "c#{slot}", state)} else #{tail} end"

      {line, "o#{slot}", state, slot + 1}
    else
      _ -> fallback(state, slot, node)
    end
  end

  defp emit_render(node, state, slot) do
    node = declared_args(node, state)

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

  # Under an ordered pass the callee's own module is already built and is only looked up: building
  # it here is what would define a template inside its own definition. A callee the caller's
  # constants specialise is a different module — named for its content, unique to those bindings,
  # so nothing else can be defining it and it is compiled here as it always was.
  defp callee_module(tree, bound, opts, name) do
    if Keyword.get(opts, :name_modules, false) and map_size(bound) == 0,
      do: compiled(tree, bound, Keyword.put(opts, :name, name)),
      else: ensure_compiled(tree, bound, opts)
  end

  # A fixed `{% render %}` target compiles the callee with the caller's constants bound.
  defp inline_render(node, state, slot) do
    node = declared_args(node, state)

    with {:ok, name} <- const_value(node.template, state.known),
         true <- is_binary(name),
         {:ok, vars_code, state} <- render_vars(node, "c#{slot}", state),
         {:ok, bound} <- const_render_args(node, state.known),
         {:ok, tree} <- load_template(name, state.opts),
         # A callee holding break/continue gets its own module rather than inlining.
         false <- loop_control?(tree),
         # A callee with no module of its own is rendered by name instead: emitting a call to a
         # module nobody built would raise where the caller runs.
         {:ok, module} <- callee_module(tree, bound, state.opts, name) do
      case {vars_code, constant_output(module)} do
        # a `for` render repeats its callee, so a constant body still varies in count
        {{:each, var, source}, _} ->
          line =
            "{o#{slot}, c#{slot + 1}} = " <>
              "render_each(#{inspect(module)}, #{source}, #{literal(var)}, c#{slot}, o, " <>
              "#{literal(name)})"

          {:ok, line, "o#{slot}", state, slot + 1}

        {vars, nil} ->
          line =
            "{o#{slot}, c#{slot + 1}} = " <>
              "render_module(#{inspect(module)}, #{vars}, c#{slot}, o, #{literal(name)})"

          {:ok, line, "o#{slot}", state, slot + 1}

        {_vars, constant} ->
          {:ok, "", literal(constant), state, slot}
      end
    else
      _ -> :error
    end
  end

  # `{% render %}` is isolated, so an argument the callee never names cannot reach it.
  defp declared_args(%{arguments: arguments} = node, state) when is_map(arguments) do
    with {:ok, name} <- const_value(node.template, state.known),
         true <- is_binary(name),
         {:ok, tree} <- load_template(name, state.opts),
         read = root_reads(tree, MapSet.new()),
         false <- opaque_read?(read, state.opts) do
      %{
        node
        | arguments: Map.filter(arguments, &MapSet.member?(read, argument_root(elem(&1, 0))))
      }
    else
      _ -> node
    end
  end

  defp declared_args(node, _state), do: node

  # A host whose values can carry more liquid names the roots that hide it: given a whole such map
  # the callee can resolve names no tree of its shows, so its read set is not the whole story.
  defp opaque_read?(read, opts) do
    opts |> Keyword.get(:opaque_roots, []) |> Enum.any?(&MapSet.member?(read, &1))
  end

  defp argument_root(key) do
    case :binary.split(key, ".") do
      [root | _rest] -> root
    end
  end

  defp root_reads(%Variable{identifier: identifier} = variable, acc),
    do: variable |> Map.from_struct() |> root_reads(MapSet.put(acc, identifier))

  defp root_reads(list, acc) when is_list(list), do: Enum.reduce(list, acc, &root_reads/2)

  defp root_reads(%{__struct__: _} = struct, acc),
    do: struct |> Map.from_struct() |> root_reads(acc)

  defp root_reads(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> root_reads(acc)

  defp root_reads(map, acc) when is_map(map),
    do: map |> Map.values() |> Enum.reduce(acc, &root_reads/2)

  defp root_reads(_other, acc), do: acc

  # The tree the running pass already parsed for `name`, else the file: callees compile first, so
  # a caller finds its callee there and the theme is read once however often it is rendered.
  defp load_template(name, opts) do
    with :error <- Map.fetch(Keyword.get(opts, :trees, %{}), name) do
      if Keyword.has_key?(opts, :file_system), do: read_template(name, opts), else: :error
    end
  end

  defp read_template(name, opts) do
    case Gas.precompile(name, Keyword.delete(opts, :codegen)) do
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

  # `'bg-{{ s.bg_role }}'` is a literal once the bindings settle what it interpolates. Themes
  # accumulate class names this way, so leaving these unfolded stops folding at the first one.
  defp const_value(%Literal{interp_ast: %Gas.Template{parsed_template: tree}}, known),
    do: const_nodes(List.wrap(tree), known)

  defp const_value(%Variable{} = variable, known) do
    case static_keys(variable) do
      nil -> resolve_known(known, const_keys(variable, known))
      keys -> resolve_known(known, keys)
    end
  end

  defp const_value(_argument, _known), do: :unknown

  defp const_nodes(nodes, known) do
    Enum.reduce_while(nodes, {:ok, ""}, fn node, {:ok, acc} ->
      case interpolated_part(node, known) do
        {:ok, part} -> {:cont, {:ok, acc <> part}}
        :unknown -> {:halt, :unknown}
      end
    end)
  end

  defp interpolated_part(%Text{text: text}, _known), do: {:ok, text}

  defp interpolated_part(%Object{argument: argument, filters: filters}, known) do
    with {:ok, value} <- const_expression(argument, filters, known),
         {:ok, string} <- stringify_const(value) do
      {:ok, string}
    end
  end

  defp interpolated_part(_node, _known), do: :unknown

  defp stringify_const(value) do
    {:ok, Gas.Argument.stringify!(value)}
  rescue
    _ -> :unknown
  end

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

  defp elsif_chain(elsifs, ctx, state) do
    Enum.reduce_while(List.wrap(elsifs), {:ok, []}, fn {test, branch}, {:ok, acc} ->
      case condition(test, ctx, state) do
        {:ok, code} -> {:cont, {:ok, acc ++ [{code, branch}]}}
        :error -> {:halt, :error}
      end
    end)
  end

  # ---- expressions -------------------------------------------------------
  defp expression(argument, filters, ctx, state) do
    case value(argument, ctx, state) do
      {:ok, base, state} -> guarded_chain(base, filters, ctx, state)
      :error -> :error
    end
  end

  # A chain with no filters cannot raise a filter error, so it is left bare.
  defp guarded_chain(base, filters, ctx, state) when filters in [nil, []],
    do: filter_chain(base, filters, ctx, state)

  defp guarded_chain(base, filters, ctx, state) do
    with {:ok, code, state} <- filter_chain(base, filters, ctx, state) do
      line = filters |> List.wrap() |> List.first() |> filter_line()

      {:ok, "(try do #{code} rescue e -> filter_error(e, __STACKTRACE__, #{line}) end)", state}
    end
  end

  defp filter_line(%{loc: %{line: line}}), do: line
  defp filter_line(_filter), do: 0

  defp value(%Literal{value: value, interp_ast: nil}, _ctx, state),
    do: {:ok, literal(value), state}

  defp value(%Literal{interp_ast: %Gas.Template{parsed_template: sub}}, ctx, state) do
    {fun, state} = body(List.wrap(sub), state)
    {:ok, "IO.iodata_to_binary(elem(#{fun}(#{ctx}, o, e), 0))", state}
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
          :unknown -> read(keys, ctx, state)
        end
    end
  end

  defp value(_other, _ctx, _state), do: :error

  # Only against a body's entry context: a node that can rebind a variable advances the context,
  # so a read after one never sees a binding hoisted above it.
  defp read(keys, ctx, state), do: dealias(keys, state.aliases) |> emit_read(ctx, state)

  # An alias stands for the path it was bound to, so its reads share that path's hoist.
  defp dealias([root | rest] = keys, aliases) do
    case Map.fetch(aliases, root) do
      {:ok, path} -> path ++ rest
      :error -> keys
    end
  end

  defp emit_read([name], _ctx, %{locals: locals} = state) when is_map_key(locals, name),
    do: {:ok, Map.fetch!(locals, name), state}

  defp emit_read(keys, ctx, state) do
    case Map.fetch(state.extracts, keys) do
      {:ok, index} -> {:ok, extracted(index, ctx, state), state}
      :error -> emit_hoisted(keys, ctx, state)
    end
  end

  # A setting can hold liquid, and it renders against the context reading it, not the one that
  # extracted it — so a hoisted read resolves where it is used.
  defp extracted(index, ctx, state) do
    if MapSet.member?(state.raw_extracts, index),
      do: "res(elem(e, #{index}), #{ctx}, o)",
      else: "elem(e, #{index})"
  end

  defp emit_hoisted([_, _ | _] = keys, "c0" = ctx, %{hoists: hoists} = state)
       when is_list(hoists) do
    {prefix, [last]} = Enum.split(keys, length(keys) - 1)
    {binding, state} = hoist(prefix, state)

    {:ok, "resolve(walk(#{binding}, #{literal([last])}), #{ctx}, o)", state}
  end

  defp emit_hoisted([key], ctx, state) when is_binary(key),
    do: {:ok, "get1(#{ctx}, #{literal(key)}, o)", state}

  defp emit_hoisted(keys, ctx, state), do: {:ok, "get(#{ctx}, #{literal(keys)}, o)", state}

  # `{% assign s = block.settings %}` makes every `s.x` an alias for `block.settings.x`. Only a
  # name bound once in the whole tree qualifies, so no branch or iteration can rebind it.
  defp aliases(tree, bound) do
    Enum.reduce(tree, %{}, fn node, acc ->
      case alias_of(node, bound) do
        {name, path} -> Map.put(acc, name, path)
        nil -> acc
      end
    end)
  end

  defp alias_of(
         %AssignTag{
           argument: %Variable{identifier: name, accesses: []},
           object: %Object{argument: %Variable{} = source, filters: []}
         },
         bound
       ) do
    with 1 <- Map.get(bound, name),
         [_, _ | _] = keys <- static_keys(source),
         false <- Map.has_key?(bound, hd(keys)),
         false <- hd(keys) in @runtime_bound do
      {name, keys}
    else
      _ -> nil
    end
  end

  defp alias_of(_node, _bound), do: nil

  # Every name any node binds, however deep, so a rebinding anywhere disqualifies the alias.
  # A capture or an iteration variable is counted twice: neither can ever be an alias.
  defp bindings(%AssignTag{argument: %Variable{identifier: name}} = node, acc) do
    node |> Map.from_struct() |> Map.delete(:argument) |> bindings(count(acc, name))
  end

  defp bindings(%CaptureTag{argument: %Variable{identifier: name}} = node, acc) do
    bindings(node.body, acc |> count(name) |> count(name))
  end

  defp bindings(%Gas.Tags.CounterTag{argument: %Variable{identifier: name}}, acc) do
    acc |> count(name) |> count(name)
  end

  defp bindings(%ForTag{variable: %Variable{identifier: name}} = node, acc) do
    bindings([node.body, node.else_body], acc |> count(name) |> count(name))
  end

  defp bindings(%Gas.Tags.TablerowTag{variable: %Variable{identifier: name}} = node, acc) do
    bindings(Map.from_struct(node), acc |> count(name) |> count(name))
  end

  defp bindings(list, acc) when is_list(list), do: Enum.reduce(list, acc, &bindings(&1, &2))

  defp bindings(%{__struct__: _} = struct, acc),
    do: struct |> Map.from_struct() |> bindings(acc)

  defp bindings(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> bindings(acc)

  defp bindings(map, acc) when is_map(map),
    do: map |> Map.values() |> Enum.reduce(acc, &bindings(&1, &2))

  defp bindings(_other, acc), do: acc

  defp count(acc, name), do: Map.update(acc, name, 1, &(&1 + 1))

  # Every entry-rooted path the template reads, grouped by parent, so one `get_map_elements` at
  # entry answers every read of that parent — wherever in the template the read sits.
  defp extract_groups(tree, aliases, bound) do
    tree
    |> read_paths([])
    |> Enum.map(&dealias(&1, aliases))
    |> Enum.filter(fn [root | _] ->
      not Map.has_key?(bound, root) and root not in @runtime_bound
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn
      {[_bare], reads} -> reads > 1
      {_path, _reads} -> true
    end)
    |> Enum.map(fn {keys, _reads} -> keys end)
    |> Enum.group_by(fn keys -> Enum.slice(keys, 0..-2//1) end, &List.last/1)
    |> Enum.sort()
  end

  defp raw_extracts(groups) do
    {set, _next} =
      Enum.reduce(groups, {MapSet.new(), 0}, fn {prefix, keys}, {set, next} ->
        set =
          if prefix == [],
            do: set,
            else: Enum.reduce(next..(next + length(keys) - 1), set, &MapSet.put(&2, &1))

        {set, next + length(keys)}
      end)

    set
  end

  defp extract_table(groups) do
    {table, _next} =
      Enum.reduce(groups, {%{}, 0}, fn {prefix, keys}, {table, next} ->
        Enum.reduce(Enum.with_index(keys, next), {table, next + length(keys)}, fn {key, i},
                                                                                  {acc, n} ->
          {Map.put(acc, prefix ++ [key], i), n}
        end)
      end)

    table
  end

  defp extract_source([]), do: "e = {}"

  defp extract_source(groups) do
    {lines, bound} = extract_bindings(groups)

    Enum.join(lines ++ ["e = {#{Enum.join(bound, ", ")}}"], "\n            ")
  end

  defp extract_bindings(groups) do
    groups
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {{prefix, keys}, g}, {lines, bound} ->
      slots = Enum.with_index(keys)
      names = Enum.map(slots, fn {_key, i} -> "x#{g}_#{i}" end)
      pattern = Enum.map_join(slots, ", ", fn {key, i} -> "#{literal(key)} => v#{i}" end)
      fast = Enum.map_join(slots, ", ", fn {_key, i} -> "v#{i}" end)
      slow = Enum.map_join(keys, ", ", fn key -> "walk(p#{g}, #{literal([key])})" end)

      {lines ++ extract_lines(prefix, g, names, keys, pattern, fast, slow), bound ++ names}
    end)
  end

  # A bare name has no parent map to match against — `Gas.render/3` will even put a plain vars
  # map in `counter_vars` — so it takes the same scope walk `get/3` would, once.
  defp extract_lines([], _g, names, keys, _pattern, _fast, _slow) do
    Enum.zip(names, keys)
    |> Enum.map(fn {name, key} ->
      "#{name} = resolve(lookup(ctx, #{literal([key])}), ctx, opts)"
    end)
  end

  defp extract_lines(prefix, g, names, _keys, pattern, fast, slow) do
    [
      "p#{g} = lookup(ctx, #{literal(prefix)})",
      "{#{Enum.join(names, ", ")}} = case p#{g} do %{#{pattern}} -> {#{fast}}; _ -> {#{slow}} end"
    ]
  end

  defp read_paths(%Variable{} = variable, acc) do
    case static_keys(variable) do
      nil -> variable |> Map.from_struct() |> read_paths(acc)
      keys -> [keys | acc]
    end
  end

  defp read_paths(list, acc) when is_list(list), do: Enum.reduce(list, acc, &read_paths(&1, &2))

  defp read_paths(%{__struct__: _} = struct, acc),
    do: struct |> Map.from_struct() |> read_paths(acc)

  defp read_paths(tuple, acc) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> read_paths(acc)

  defp read_paths(map, acc) when is_map(map),
    do: map |> Map.values() |> Enum.reduce(acc, &read_paths(&1, &2))

  defp read_paths(_other, acc), do: acc

  defp hoist(prefix, state) do
    case List.keyfind(state.hoists, prefix, 0) do
      {^prefix, binding} ->
        {binding, state}

      nil ->
        binding = "h#{length(state.hoists)}"
        {binding, %{state | hoists: state.hoists ++ [{prefix, binding}]}}
    end
  end

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
      {:ok, [], state} when is_binary(identifier) ->
        {:ok, "get1(#{ctx}, #{literal(identifier)}, o)", state}

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
  # `and`/`or` fold only as a whole, so a settled half still reaches here.
  defp condition(test, ctx, state) do
    case const_condition(test, state.known) do
      {:ok, value} -> {:ok, literal(value)}
      :unknown -> runtime_condition(test, ctx, state)
    end
  end

  defp runtime_condition(%Gas.UnaryCondition{child_condition: nil} = test, ctx, state) do
    with true <- test.argument_filters in [nil, []],
         {:ok, code} <- condition_value(test.argument, ctx, state) do
      {:ok, "truthy(#{code})"}
    else
      _ -> :error
    end
  end

  defp runtime_condition(%Gas.BinaryCondition{child_condition: nil} = test, ctx, state) do
    with true <- test.left_argument_filters in [nil, []],
         true <- test.right_argument_filters in [nil, []],
         true <- test.operator in @operators,
         {:ok, left} <- condition_value(test.left_argument, ctx, state),
         {:ok, right} <- condition_value(test.right_argument, ctx, state) do
      {:ok, "compare(#{left}, #{literal(test.operator)}, #{right})"}
    else
      _ -> :error
    end
  end

  defp runtime_condition(%mod{child_condition: {joiner, child}} = test, ctx, state)
       when mod in [Gas.BinaryCondition, Gas.UnaryCondition] and joiner in [:and, :or] do
    with {:ok, left} <- condition(%{test | child_condition: nil}, ctx, state),
         {:ok, right} <- condition(child, ctx, state) do
      {:ok, "(#{left} #{joiner} #{right})"}
    else
      _ -> :error
    end
  end

  defp runtime_condition(_other, _ctx, _state), do: :error

  # A condition has nowhere to put a helper function or a hoisted binding, so it takes neither.
  defp condition_value(argument, ctx, state) do
    case value(argument, ctx, %{state | hoists: :off, funs: []}) do
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
      # A name belongs to the one tree being compiled. Left in, every nested compile this state
      # reaches — a callee, a setting's liquid — would claim the module the file answers to.
      opts: Keyword.delete(opts, :name),
      touched: MapSet.new(),
      const_bodies: %{},
      pure_bodies: %{},
      hoists: [],
      aliases: %{},
      extracts: %{},
      raw_extracts: MapSet.new(),
      locals: %{}
    }

  # `inspect/1` defaults truncate, which would emit a shortened template, not fail.
  defp literal(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

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
