defmodule Gas.BinaryCondition do
  @moduledoc """
  binary condition evaluator
  """
  alias Gas.{Argument, Filter}
  alias Gas.Literal.Empty

  defstruct [
    :loc,
    :child_condition,
    :left_argument,
    :operator,
    :right_argument,
    left_argument_filters: [],
    right_argument_filters: []
  ]

  @type t :: %__MODULE__{
          loc: Gas.Parser.Loc.t(),
          child_condition: {:and | :or, t | Gas.UnaryCondition.t()} | nil,
          left_argument: Argument.t(),
          left_argument_filters: [Filter.t()],
          operator: Gas.Lexer.operator(),
          right_argument: Argument.t(),
          right_argument_filters: [Filter.t()]
        }

  defmacro match_empty?(expr) do
    quote do
      unquote(expr) in [nil, [], "", %{}, %Empty{}]
    end
  end

  @spec eval({term, Gas.Lexer.operator(), term}) :: {:ok, boolean} | {:error, binary}

  # == with empty
  def eval({v1, :==, empty}) when match_empty?(empty) and is_map(v1) and not is_struct(v1),
    do: {:ok, v1 == %{}}

  def eval({empty, :==, v2}) when match_empty?(empty) and is_map(v2) and not is_struct(v2),
    do: {:ok, v2 == %{}}

  def eval({v1, :==, empty}) when match_empty?(empty) and is_list(v1), do: {:ok, v1 == []}
  def eval({empty, :==, v2}) when match_empty?(empty) and is_list(v2), do: {:ok, v2 == []}

  def eval({v1, :==, empty}) when match_empty?(empty) and is_binary(v1),
    do: {:ok, String.trim(v1) == ""}

  def eval({empty, :==, v2}) when match_empty?(empty) and is_binary(v2),
    do: {:ok, String.trim(v2) == ""}

  # != with empty
  def eval({v1, :!=, empty}) when match_empty?(empty), do: {:ok, not match_empty?(v1)}
  def eval({empty, :!=, v2}) when match_empty?(empty), do: {:ok, not match_empty?(v2)}
  def eval({v1, :<>, empty}) when match_empty?(empty), do: {:ok, not match_empty?(v1)}
  def eval({empty, :<>, v2}) when match_empty?(empty), do: {:ok, not match_empty?(v2)}

  # contains
  def eval({nil, :contains, _}), do: {:ok, false}
  def eval({_, :contains, nil}), do: {:ok, false}
  def eval({v1, :contains, v2}) when is_list(v1), do: {:ok, v2 in v1}

  def eval({v1, :contains, v2}) when is_binary(v1) and is_binary(v2),
    do: {:ok, String.contains?(v1, v2)}

  def eval({v1, :contains, v2}) when is_binary(v1),
    do: {:ok, String.contains?(v1, to_string(v2))}

  def eval({_v1, :contains, _v2}), do: {:ok, false}

  # numeric vs nil comparisons
  def eval({v1, :<=, nil}) when is_number(v1), do: {:ok, false}
  def eval({v1, :<, nil}) when is_number(v1), do: {:ok, false}
  def eval({nil, :>=, v2}) when is_number(v2), do: {:ok, false}
  def eval({nil, :>, v2}) when is_number(v2), do: {:ok, false}

  # type mismatch errors
  def eval({v1, op, v2})
      when op in [:<, :<=, :>, :>=, :==, :!=, :<>] and is_binary(v1) and is_number(v2),
      do: eval({to_number(v1), op, v2})

  def eval({v1, op, v2})
      when op in [:<, :<=, :>, :>=, :==, :!=, :<>] and is_number(v1) and is_binary(v2),
      do: eval({v1, op, to_number(v2)})

  # != and <> normalized
  def eval({v1, :!=, v2}), do: {:ok, v1 != v2}
  def eval({v1, :<>, v2}), do: {:ok, v1 != v2}

  def eval({v1, op, v2}) when op in [:==, :<, :<=, :>, :>=],
    do: {:ok, apply(Kernel, op, [v1, v2])}

  # Catch-all: unsupported operator
  def eval({_v1, op, _v2}), do: {:error, "unsupported operator #{inspect(op)}"}

  @int_regex ~r/^-?\d+$/
  @float_regex ~r/^-?\d+\.\d+$/

  defp to_number(value) do
    value = String.trim(value)

    cond do
      Regex.match?(@int_regex, value) ->
        String.to_integer(value)

      Regex.match?(@float_regex, value) ->
        String.to_float(value)

      true ->
        nil
    end
  end
end
