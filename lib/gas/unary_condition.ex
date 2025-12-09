defmodule Gas.UnaryCondition do
  @moduledoc false
  defstruct [:loc, :child_condition, :argument, argument_filters: []]

  @type t :: %__MODULE__{
          loc: Gas.Parser.Loc.t(),
          argument: Gas.Argument.t(),
          argument_filters: [Gas.Filter.t()],
          child_condition: {:and | :or, t | Gas.BinaryCondition.t()}
        }

  def eval(value) do
    if value do
      true
    else
      false
    end
  end
end
