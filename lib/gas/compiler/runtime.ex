defmodule Gas.Compiler.Runtime do
  @moduledoc """
  The cold operations `Gas.Compiler.Codegen` emits calls to.

  The hot path — variable lookup, assign, stringify, compare — is emitted inline
  in each generated module instead.
  """

  alias Gas.{Context, Template}

  require Logger

  @doc """
  What a filter chain renders when a filter in it raises.

  A filter given an argument of the wrong shape is a template error in Liquid, not a crash: the
  interpreter guards each application and renders the message in place of the value. Compiled
  chains guard once and read the filter's name off the stacktrace, which says the same thing for
  the price of one guard rather than one per filter.
  """
  @errors_key {__MODULE__, :filter_errors}

  @spec filter_error(Exception.t(), Exception.stacktrace(), pos_integer) :: binary
  def filter_error(error, stacktrace, line) do
    # Built as the error the interpreter would have recorded and then rendered, rather than as a
    # copy of how that reads: one of them changing shape must not leave the two disagreeing.
    recorded = %Gas.ArgumentError{
      loc: %Gas.Parser.Loc{line: line, column: 0},
      message: "Filter: #{failing_filter(stacktrace)} #{String.trim(inspect(error))}"
    }

    # A filter is a value in an expression, with no context in reach to write to. Left here for
    # the render that is running to collect, so the error reaches the caller and not only the page.
    Process.put(@errors_key, [recorded | Process.get(@errors_key, [])])

    Exception.message(recorded)
  end

  @doc """
  Adds the filter errors this render collected to `context`.

  Emitted only by a module that has a filter to guard, and read once per render of it, so a
  template without filters pays nothing for this.
  """
  @spec absorb_filter_errors(Context.t()) :: Context.t()
  def absorb_filter_errors(%Context{} = context) do
    case Process.get(@errors_key) do
      nil ->
        context

      errors ->
        Process.delete(@errors_key)
        Context.put_errors(context, Enum.reverse(errors))
    end
  end

  # Filters live in submodules of `Gas.Filters.Filter`, and the raise comes from whatever the
  # filter called, so the filter is the first frame under that namespace rather than the top one.
  defp failing_filter([{module, function, _arity_or_args, _location} | rest]) do
    if module == Gas.Filters.Filter or
         String.starts_with?(Atom.to_string(module), "Elixir.Gas.Filters.Filter."),
       do: function,
       else: failing_filter(rest)
  end

  defp failing_filter([]), do: "unknown"

  @doc """
  The error a compiled module raises when handed a context it was not compiled for.

  Generated code reads variables the way the default matcher and scopes do and lets an undefined
  one be nil. Nothing about those choices can be decided per render, so a context that differs is
  a caller mistake to report rather than a reason to go and interpret the template instead.
  """
  @spec uncompiled_context(module, Context.t()) :: Exception.t()
  def uncompiled_context(module, %Context{} = context) do
    ArgumentError.exception(
      "#{inspect(module)} was compiled for the default matcher, scopes and lax variables, and " <>
        "cannot render a context with matcher_module: #{inspect(context.matcher_module)}, " <>
        "strict_variables: #{inspect(context.strict_variables)}. Render the template's tree " <>
        "instead of its module for these."
    )
  end

  @doc "Logs `message.()` the first time `key` is seen, for a condition that repeats every render."
  def log_once(key, message) when is_function(message, 0) do
    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.warning(message.())
    end

    :ok
  end

  def forloop(index, length, parentloop, name) do
    %{
      "index" => index + 1,
      "index0" => index,
      "rindex" => length - index,
      "rindex0" => length - index - 1,
      "first" => index == 0,
      "last" => length == index + 1,
      "length" => length,
      "parentloop" => parentloop,
      "name" => name
    }
  end

  def iter_put(context, key, value),
    do: %{context | iteration_vars: Map.put(context.iteration_vars, key, value)}

  def iter_cleanup(context, key, parent_forloop) do
    vars = Map.delete(context.iteration_vars, key)

    vars =
      if key != "forloop" and parent_forloop != nil do
        Map.put(vars, "forloop", parent_forloop)
      else
        Map.delete(vars, "forloop")
      end

    %{context | iteration_vars: vars}
  end

  def register(context, name, value),
    do: %{context | registers: Map.put(context.registers, name, value)}

  def enumerate(nil), do: []
  def enumerate(list) when is_list(list), do: list

  def enumerate(%Range{first: first, last: last}) when first <= last,
    do: Enum.to_list(first..last)

  def enumerate(%Range{}), do: []
  def enumerate(map) when is_map(map) and not is_struct(map), do: Enum.to_list(map)
  def enumerate(other), do: [other]

  @doc """
  Renders a compiled callee with a fresh context, applying the same option
  overrides `Gas.render/3` would. `template` names it for `:instrument`.
  """
  def render_module(module, vars, context, opts, template \\ nil) do
    instrument(opts, template, fn ->
      {out, errors} =
        reusing(template, vars, opts, fn ->
          {out, inner} = module.render(inner_context(vars, opts), opts)
          {out, inner.errors}
        end)

      {out, carry_errors(context, errors)}
    end)
  end

  @doc """
  Runs `fun` through the host's `:memo`, which decides whether this render can be
  reused and under what key.

  `{% render %}` is isolated — the callee sees a fresh context built only from
  `vars` — so its output is fixed by the name and those arguments. Which of them
  the output actually turns on is the host's to know, so the hook is handed the
  name, the arguments and a zero-arity function returning `{output, errors}`.
  """
  @spec reusing(term, map, keyword, (-> {iodata, list})) :: {iodata, list}
  def reusing(name, vars, opts, fun) when is_binary(name) do
    case Keyword.get(opts, :memo) do
      memo when is_function(memo, 3) -> memo.(name, vars, fun)
      _absent -> fun.()
    end
  end

  def reusing(_name, _vars, _opts, fun), do: fun.()

  defp carry_errors(context, []), do: context
  defp carry_errors(context, errors), do: Context.put_errors(context, errors)

  @doc "`{% render x for list as name %}` — one render per element, timed as one."
  def render_each(module, value, name, context, opts, template \\ nil)

  def render_each(module, value, name, context, opts, template) when is_list(value) do
    instrument(opts, template, fn -> each(module, value, name, context, opts) end)
  end

  def render_each(module, value, name, context, opts, template),
    do: render_module(module, %{name => value}, context, opts, template)

  defp each(module, value, name, context, opts) do
    length = Enum.count(value)

    value
    |> Enum.with_index(0)
    |> Enum.reduce({[], context}, fn {element, index}, {acc, ctx} ->
      inner = %{
        inner_context(%{name => element}, opts)
        | iteration_vars: %{"forloop" => render_forloop(index, length)}
      }

      {out, inner} = module.render(inner, opts)
      {[acc, out], merge_errors(ctx, inner)}
    end)
  end

  @doc """
  Runs `fun` through the host's `:instrument`, so it can time the render of `template` by name.

  Every `{% render %}` goes through here, compiled or interpreted, and a render with no name to
  report goes straight through.
  """
  @spec instrument(keyword, term, (-> term)) :: term
  def instrument(opts, template, fun) when is_binary(template) do
    case Keyword.get(opts, :instrument) do
      instrument when is_function(instrument, 2) -> instrument.(template, fun)
      nil -> fun.()
    end
  end

  def instrument(_opts, _template, fun), do: fun.()

  # The default is built once: `Keyword.get/3` evaluates it on every callee render otherwise.
  @default_scopes Context.default_scopes()

  defp inner_context(vars, opts) do
    %Context{
      vars: vars,
      matcher_module: Keyword.get(opts, :matcher_module, Gas.Matcher),
      scopes: Keyword.get(opts, :scopes, @default_scopes),
      strict_variables: Keyword.get(opts, :strict_variables, false)
    }
  end

  # `render for` builds a smaller forloop than `{% for %}` does.
  defp render_forloop(index, length) do
    %{
      "index" => index + 1,
      "index0" => index,
      "rindex" => length - index,
      "rindex0" => length - index - 1,
      "first" => index == 0,
      "last" => length == index + 1,
      "length" => length
    }
  end

  @doc """
  Renders a setting that carried liquid, the way `Gas.Context.get_in/4` does.

  Compiled reads walk the vars map directly, so without this an interpolated
  setting reaches `str/1` as a struct and raises.
  """
  def resolve(
        %Gas.InterpolatedString{ast: %Template{module: nil, parsed_template: tree}},
        context,
        opts
      ) do
    {io, _ctx} = Gas.render(tree, context, opts)
    IO.iodata_to_binary(io)
  end

  def resolve(%Gas.InterpolatedString{ast: %Template{module: module}}, context, opts) do
    {io, _ctx} = module.render(context, opts)
    IO.iodata_to_binary(io)
  end

  def resolve(value, _context, _opts), do: value

  @doc "Carries an inlined callee's errors back to the caller's context."
  def merge_errors(context, %{errors: []}), do: context
  def merge_errors(context, inner), do: Context.put_errors(context, inner.errors)

  @doc "`(a..b)` — a non-integer bound falls back to 0, as the interpreter does."
  def range(start, finish), do: to_int(start)..to_int(finish)//1

  defp to_int(value) do
    case Gas.NumberHelper.to_integer(value) do
      {:ok, integer} -> integer
      _ -> 0
    end
  end

  def head_map(value) when is_map(value), do: value
  def head_map(_value), do: %{}

  @doc """
  Applies `{% for %}`'s offset/limit/reversed, mirroring the interpreter.

  `offset: continue` resumes from the register the previous loop of the same
  name left behind, so the register is written even when the result is empty.
  """
  def for_prepare(list, offset, limit, reversed?, context, for_name) do
    with {:ok, start} <- for_offset(offset, context, for_name),
         {:ok, finish} <- for_limit(list, limit) do
      last = start + finish
      sliced = Enum.slice(list, start..last//1)

      {:ok, if(reversed?, do: Enum.reverse(sliced), else: sliced),
       register(context, for_name, last + 1)}
    end
  end

  defp for_offset(nil, _context, _for_name), do: {:ok, 0}
  defp for_offset(:continue, context, for_name), do: {:ok, context.registers[for_name] || 0}
  defp for_offset(value, _context, _for_name), do: Gas.NumberHelper.to_integer(value)

  defp for_limit(list, nil), do: {:ok, Enum.count(list)}

  defp for_limit(_list, value) do
    with {:ok, limit} <- Gas.NumberHelper.to_integer(value), do: {:ok, limit - 1}
  end

  @doc "A bad offset/limit renders the interpreter's message and records the error."
  def for_error(message, loc, context) do
    exception = %Gas.ArgumentError{loc: loc, message: message}
    {Exception.message(exception), Context.put_errors(context, exception)}
  end

  @doc "`{% render %}` with its arguments already evaluated by the caller."
  def render_partial(name, vars, context, opts, loc) do
    instrument(opts, name, fn ->
      {out, errors} = reusing(name, vars, opts, fn -> partial(name, vars, opts, loc) end)
      {out, carry_errors(context, errors)}
    end)
  end

  # Returns only what the arguments settle, so a reused render can be handed back verbatim. The
  # name is turned into the module it compiles to and that module is called — the same dispatch a
  # fixed callee gets, minus knowing the name early. Nothing is read, parsed or looked up.
  defp partial(name, vars, opts, loc) do
    case Gas.Compiler.Codegen.module_for(name) do
      {:ok, module} -> dispatch_partial(module, name, vars, opts, loc)
      :error -> {[], [uncompilable_name(name, loc)]}
    end
  end

  defp dispatch_partial(module, name, vars, opts, loc) do
    if :erlang.module_loaded(module) do
      {out, inner} = module.render(inner_context(vars, opts), opts)
      {out, inner.errors}
    else
      {[], [uncompiled_partial(module, name, loc)]}
    end
  end

  defp uncompilable_name(name, loc) do
    %Gas.FileSystem.Error{loc: loc, reason: "#{inspect(name)} is not a template name"}
  end

  # A render reaches its callee's module by name, so the callee has to have been compiled. Every
  # template of a theme is, in one pass; a name outside that pass is a name nothing renders.
  defp uncompiled_partial(module, name, loc) do
    %Gas.FileSystem.Error{
      loc: loc,
      reason:
        "#{name} has no compiled module (#{inspect(module)}). Templates are compiled by " <>
          "Gas.precompile_all/2; a name it did not cover cannot be rendered."
    }
  end
end
