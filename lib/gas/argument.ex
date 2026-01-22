defmodule Gas.Argument do
  @moduledoc false
  alias Gas.{
    Context,
    Filter,
    Lexer,
    Literal,
    StandardFilter,
    UndefinedVariableError,
    Variable
  }

  alias Gas.Parser.Loc
  import Gas.NumberHelper, only: [to_integer: 1]

  @type t :: Variable.t() | Literal.t() | Gas.Range.t()

  @spec parse(Lexer.tokens()) ::
          {:ok, t, Lexer.tokens()} | {:error, binary, Lexer.loc()}
  def parse(tokens) do
    case Literal.parse(tokens) do
      {:ok, literal, rest} -> {:ok, literal, rest}
      {:error, _, _} -> parse_range(tokens)
    end
  end

  defp parse_range(tokens) do
    case Gas.Range.parse(tokens) do
      {:ok, range, rest} -> {:ok, range, rest}
      {:error, _, _} -> parse_variable(tokens)
    end
  end

  defp parse_variable(tokens) do
    case Variable.parse(tokens) do
      {:ok, var, rest} ->
        {:ok, var, rest}

      {:error, "Variable expected", meta} ->
        {:error, "Argument expected", meta}

      {:error, reason, meta} ->
        {:error, reason, meta}
    end
  end

  @spec parse_with_filters(Lexer.tokens()) ::
          {:ok, t, [Filter.t()], Lexer.tokens()} | {:error, binary, Lexer.loc()}
  def parse_with_filters(tokens) do
    with {:ok, argument, rest} <- parse(tokens),
         {:ok, filters, rest} <- filters(rest) do
      {:ok, argument, filters, rest}
    end
  end

  defp filters(tokens, filters \\ [])

  defp filters([{:pipe, _}, {:identifier, meta, filter}, {:colon, colon_meta} | rest], filters) do
    case arguments(rest) do
      {:ok, [], positional_arguments, _} when map_size(positional_arguments) == 0 ->
        {:error, "Arguments expected", colon_meta}

      {:ok, positional_arguments, named_arguments, rest} ->
        filter = %Filter{
          loc: struct!(Loc, meta),
          function: filter,
          positional_arguments: positional_arguments,
          named_arguments: named_arguments
        }

        filters(rest, [filter | filters])

      error ->
        error
    end
  end

  defp filters([{:pipe, _}, {:identifier, meta, filter} | rest], filters) do
    filter = %Filter{
      loc: struct!(Loc, meta),
      function: filter,
      positional_arguments: [],
      named_arguments: %{}
    }

    filters(rest, [filter | filters])
  end

  defp filters([{:pipe, meta} | _], _filters) do
    {:error, "Filter expected", meta}
  end

  defp filters(tokens, filters) do
    {:ok, Enum.reverse(filters), tokens}
  end

  defp arguments(tokens, positional_arguments \\ [], named_arguments \\ %{})

  defp arguments([{:end, _}] = tokens, positional_arguments, named_arguments),
    do: {:ok, Enum.reverse(positional_arguments), named_arguments, tokens}

  # Another filter coming up
  defp arguments([{:pipe, _} | _rest] = tokens, positional_arguments, named_arguments) do
    {:ok, Enum.reverse(positional_arguments), named_arguments, tokens}
  end

  # named argument
  defp arguments([{:identifier, _, key}, {:colon, _} | rest], positional, named) do
    with {:ok, value, rest} <- parse(rest) do
      case rest do
        [{:comma, _} | rest] ->
          arguments(rest, positional, Map.put(named, key, value))

        _ ->
          {:ok, positional, Map.put(named, key, value), rest}
      end
    end
  end

  # positional argument
  defp arguments(tokens, positional, named) do
    case parse(tokens) do
      {:ok, value, rest} ->
        case rest do
          [{:comma, _} | rest] ->
            arguments(rest, positional ++ [value], named)

          _ ->
            {:ok, positional ++ [value], named, rest}
        end

      error ->
        error
    end
  end

  @doc "Similar to get/4 but outputs a printable representation"
  @spec render(t, Context.t(), [Filter.t()], Keyword.t()) :: {:ok, binary, Context.t()}
  def render(arg, context, filters, opts \\ []) do
    {:ok, value, context} = get(arg, context, filters, opts)

    {:ok, stringify!(value), context}
  end

  def stringify!(value) do
    value
    |> stringify_iolist!()
    |> IO.iodata_to_binary()
  end

  defp stringify_iolist!(value) when is_list(value) do
    Enum.map(value, &stringify_iolist!/1)
  end

  defp stringify_iolist!(value) when is_map(value) and not is_struct(value) do
    inspect(value)
  end

  defp stringify_iolist!(%Literal.Empty{}), do: ""

  defp stringify_iolist!(%Range{first: first, last: last}) do
    [stringify_iolist!(first), "..", stringify_iolist!(last)]
  end

  defp stringify_iolist!(value) when is_tuple(value) and tuple_size(value) == 2 do
    [stringify_iolist!(elem(value, 0)), stringify_iolist!(elem(value, 1))]
  end

  defp stringify_iolist!(value), do: to_string(value)

  @spec get(t, Context.t(), [Filter.t()], Keyword.t()) :: {:ok, term, Context.t()}
  def get(arg, context, filters, opts \\ []) do
    scopes = Keyword.get(opts, :scopes, [:iteration_vars, :vars, :counter_vars])
    strict_variables = Keyword.get(opts, :strict_variables, false)

    case do_get(arg, context, scopes, opts) do
      {:ok, value, context} ->
        {value, context} = maybe_apply_interpolation(value, context, opts)
        {value, context} = apply_filters(value, filters, context, opts)
        {:ok, value, context}

      {:error, {:not_found, key}, context} ->
        context =
          if strict_variables do
            Context.put_errors(context, %UndefinedVariableError{
              variable: key,
              original_name: arg.original_name,
              loc: arg.loc
            })
          else
            context
          end

        {value, context} = apply_filters(nil, filters, context, opts)
        {:ok, value, context}
    end
  end

  defp do_get(%Literal{value: value}, context, _scopes, _options), do: {:ok, value, context}

  defp do_get(%Variable{} = variable, context, scopes, options),
    do: Context.get_in(context, variable, scopes, options)

  defp do_get(%Gas.Range{} = range, context, _scopes, options) do
    {:ok, start, context} = get(range.start, context, [], options)
    {:ok, finish, context} = get(range.finish, context, [], options)

    start =
      case to_integer(start) do
        {:ok, integer} -> integer
        _ -> 0
      end

    finish =
      case to_integer(finish) do
        {:ok, integer} -> integer
        _ -> 0
      end

    {:ok, start..finish//1, context}
  end

  defp maybe_apply_interpolation(input, context, opts) when is_bitstring(input) do
    if String.contains?(input, "{{") and String.contains?(input, "}}") do
      with {:ok, parsed} <- Gas.parse(input, opts),
           {:ok, rendered_text, errors} <- Gas.render(parsed, context, opts) do
        {IO.iodata_to_binary(rendered_text), Context.put_errors(context, Enum.reverse(errors))}
      else
        {:error, %Gas.TemplateError{} = error} ->
          {input, Context.put_errors(context, error)}

        {:error, errors, rendered_text} ->
          {IO.iodata_to_binary(rendered_text), Context.put_errors(context, Enum.reverse(errors))}
      end
    else
      {input, context}
    end
  end

  defp maybe_apply_interpolation(input, context, _opts) do
    {input, context}
  end

  defp apply_filters(input, nil, context, _opts), do: {input, context}
  defp apply_filters(input, [], context, _opts), do: {input, context}

  defp apply_filters(input, [filter | filters], context, opts) do
    %Filter{
      loc: loc,
      function: filter,
      positional_arguments: args,
      named_arguments: named_args
    } = filter

    {values, context} =
      Enum.reduce(args, {[], context}, fn arg, {values, context} ->
        {:ok, value, context} = get(arg, context, [], opts)

        {[value | values], context}
      end)

    {named_values, context} =
      Enum.reduce(named_args, {%{}, context}, fn {key, value}, {named_values, context} ->
        {:ok, named_value, context} = get(value, context, [], opts)

        {Map.put(named_values, key, named_value), context}
      end)

    filter_args =
      if named_values != %{} do
        [input | Enum.reverse(values)] ++ [named_values]
      else
        [input | Enum.reverse(values)]
      end

    filter
    |> StandardFilter.apply(filter_args, loc, opts)
    |> case do
      {:error, exception} ->
        {Exception.message(exception), Context.put_errors(context, exception)}

      {:ok, value} ->
        {value, context}
        apply_filters(value, filters, context, opts)
    end
  end
end
