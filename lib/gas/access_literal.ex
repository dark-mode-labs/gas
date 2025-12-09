defmodule Gas.AccessLiteral do
  @moduledoc false
  @enforce_keys [:loc, :value]
  defstruct [:loc, :value]
  @type t :: %__MODULE__{loc: Gas.Parser.Loc.t(), value: integer | binary}

  defimpl String.Chars do
    def to_string(access), do: inspect(access.value)
  end
end
