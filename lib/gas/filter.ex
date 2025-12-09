defmodule Gas.Filter do
  @enforce_keys [:loc, :function, :positional_arguments, :named_arguments]
  defstruct [:loc, :function, :positional_arguments, :named_arguments]

  @type t :: %__MODULE__{
          loc: Gas.Parser.Loc.t(),
          function: binary,
          positional_arguments: [Gas.Argument.t()],
          named_arguments: %{binary => Gas.Argument.t()}
        }
end
