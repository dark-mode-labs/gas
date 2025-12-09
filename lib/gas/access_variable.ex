defmodule Gas.AccessVariable do
  @moduledoc false
  @enforce_keys [:loc, :variable]
  defstruct [:loc, :variable]
  @type t :: %__MODULE__{loc: Gas.Parser.Loc.t(), variable: Gas.Variable.t()}

  defimpl String.Chars do
    def to_string(access), do: Kernel.to_string(access.variable)
  end
end
