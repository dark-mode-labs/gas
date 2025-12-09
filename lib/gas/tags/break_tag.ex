defmodule Gas.Tags.BreakTag do
  @enforce_keys [:loc]
  defstruct [:loc]

  @behaviour Gas.Tag

  @impl true
  def parse("break", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:tokens, [{:end, _}]} <- {:tokens, tokens} do
      {:ok, %__MODULE__{loc: loc}, context}
    else
      {:tokens, tokens} -> {:error, "Unexpected token", Gas.Parser.meta_head(tokens)}
      {:error, reason, _rest, loc} -> {:error, reason, loc}
    end
  end

  defimpl Gas.Renderable do
    def render(_tag, context, _options) do
      throw({:break_exp, [], context})
    end
  end
end
