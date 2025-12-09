defmodule Gas.Variable do
  @moduledoc false
  alias Gas.Parser.Loc
  alias Gas.{AccessLiteral, AccessVariable}
  alias Gas.Literal

  @enforce_keys [:loc, :identifier, :accesses, :original_name]
  defstruct [:loc, :identifier, :accesses, :original_name]

  @type accesses :: [AccessVariable | AccessLiteral]
  @type t :: %__MODULE__{loc: Gas.Parser.Loc.t(), identifier: binary | nil, accesses: accesses}

  defimpl String.Chars do
    def to_string(variable), do: variable.original_name
  end

  @literals ~w(empty nil false true blank)

  @spec parse(Gas.Lexer.tokens()) ::
          {:ok, t | Literal.t(), Gas.Lexer.tokens()} | {:error, binary, Gas.Lexer.loc()}
  def parse(tokens) do
    case tokens do
      [{:identifier, meta, identifier} | rest] ->
        do_parse_identifier(identifier, meta, rest)

      [{:open_square, meta} | _] ->
        case access(tokens) do
          {:ok, rest, accesses, accesses_original_name} ->
            original_name = Enum.join(accesses_original_name)

            {:ok,
             %__MODULE__{
               loc: struct!(Loc, meta),
               identifier: nil,
               accesses: accesses,
               original_name: original_name
             }, rest}

          {:error, _, meta} ->
            {:error, "Argument expected", meta}
        end

      _ ->
        {:error, "Variable expected", Gas.Parser.meta_head(tokens)}
    end
  end

  defp do_parse_identifier(identifier, meta, rest) do
    with {:ok, rest, accesses, accesses_original_name} <- access(rest) do
      if identifier in @literals and accesses == [] do
        {:ok, %Literal{loc: struct!(Loc, meta), value: literal(identifier)}, rest}
      else
        original_name = "#{identifier}" <> Enum.join(accesses_original_name)

        {:ok,
         %__MODULE__{
           loc: struct!(Loc, meta),
           identifier: identifier,
           accesses: accesses,
           original_name: original_name
         }, rest}
      end
    end
  end

  # Should return a literal ONLY if there is no access after. Must check if nil, true and false need this also
  defp literal(identifier) do
    case identifier do
      "nil" -> nil
      "true" -> true
      "false" -> false
      "empty" -> %Literal.Empty{}
      "blank" -> ""
    end
  end

  defp access(tokens, accesses \\ [], original_name \\ [])

  defp access(
         [{:open_square, _}, {:integer, meta, number}, {:close_square, _} | rest],
         accesses,
         original_name
       ) do
    acc = %AccessLiteral{loc: struct!(Loc, meta), value: number}
    access(rest, [acc | accesses], ["[#{number}]" | original_name])
  end

  defp access(
         [{:open_square, _}, {:string, meta, string, quotes}, {:close_square, _} | rest],
         accesses,
         original_name
       ) do
    acc = %AccessLiteral{loc: struct!(Loc, meta), value: string}
    quotes = IO.chardata_to_string([quotes])
    access(rest, [acc | accesses], ["[#{quotes}#{string}#{quotes}]" | original_name])
  end

  defp access([{:open_square, _}, {:identifier, meta, _} | _] = tokens, accesses, original_name) do
    case parse(tl(tokens)) do
      {:ok, variable, [{:close_square, _} | rest]} ->
        acc = %AccessVariable{loc: struct!(Loc, meta), variable: variable}
        access(rest, [acc | accesses], ["[#{variable.original_name}]" | original_name])

      {:ok, _, rest} ->
        {:error, "Argument access mal terminated", Gas.Parser.meta_head(rest)}

      error ->
        error
    end
  end

  defp access([{:dot, _}, {:identifier, meta, identifier} | rest], accesses, original_name) do
    acc = %AccessLiteral{loc: struct!(Loc, meta), value: identifier}
    access(rest, [acc | accesses], [".#{identifier}" | original_name])
  end

  defp access([{:open_square, meta} | _], _accesses, _original_name) do
    {:error, "Argument access expected", meta}
  end

  defp access(tokens, accesses, original_name) do
    {:ok, tokens, Enum.reverse(accesses), Enum.reverse(original_name)}
  end
end
