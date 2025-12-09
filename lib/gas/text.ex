defmodule Gas.Text do
  @moduledoc false
  @enforce_keys [:loc, :text]
  defstruct [:loc, :text]
  @type t :: %__MODULE__{loc: Gas.Parser.Loc.t(), text: binary}

  defimpl Gas.Renderable do
    def render(text, context, _options) do
      {text.text, context}
    end
  end

  defimpl Gas.Block do
    def blank?(text) do
      String.trim(text.text) == ""
    end
  end
end
