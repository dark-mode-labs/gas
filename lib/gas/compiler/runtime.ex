defmodule Gas.Compiler.Runtime do
  @moduledoc """
  The cold operations `Gas.Compiler.Codegen` emits calls to.

  The hot path — variable lookup, assign, stringify, compare — is emitted inline
  in each generated module instead.
  """

  alias Gas.{Context, Template}

  require Logger

  @doc """
  Reports a compiled render that raised, before its tree is re-run interpreted.

  The retry produces the same output, so a bug in generated code costs only the
  speedup — and would otherwise leave no trace at all. Reported once per module,
  because a template that raises does so on every render.
  """
  def report_fallback(module, error, stacktrace) do
    log_once({__MODULE__, :reported, module}, fn ->
      "gas: compiled render raised in #{inspect(module)}, falling back to the interpreter\n" <>
        Exception.format(:error, error, Enum.take(stacktrace, 5))
    end)
  end

  @doc "Logs `message.()` the first time `key` is seen, for a condition that repeats every render."
  def log_once(key, message) when is_function(message, 0) do
    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Logger.error(message.())
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
  overrides `Gas.render/3` would.
  """
  def render_module(module, vars, context, opts) do
    {out, inner} = module.render(inner_context(vars, opts), opts)
    {out, merge_errors(context, inner)}
  end

  @doc "`{% render x for list as name %}` — one render per element."
  def render_each(module, value, name, context, opts) when is_list(value) do
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

  def render_each(module, value, name, context, opts),
    do: render_module(module, %{name => value}, context, opts)

  defp inner_context(vars, opts) do
    %Context{
      vars: vars,
      matcher_module: Keyword.get(opts, :matcher_module, Gas.Matcher),
      scopes: Keyword.get(opts, :scopes, Context.default_scopes()),
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
    case Gas.precompile(name, Keyword.put_new(opts, :file_system, {Gas.BlankFileSystem, nil})) do
      {:ok, {_name, %Template{} = template}} -> render_into(template, vars, context, opts)
      {:ok, %Template{} = template} -> render_into(template, vars, context, opts)
      {:ok, []} -> {[], context}
      {:error, %{loc: _} = error} -> {[], Context.put_errors(context, [%{error | loc: loc}])}
      {:error, error} -> {[], Context.put_errors(context, [error])}
    end
  end

  defp render_into(template, vars, context, opts) do
    case Gas.render(template, %Context{vars: vars}, opts) do
      {:ok, out, errors} -> {out, Context.put_errors(context, Enum.reverse(errors))}
      {:error, errors, out} -> {out, Context.put_errors(context, Enum.reverse(errors))}
    end
  end
end
