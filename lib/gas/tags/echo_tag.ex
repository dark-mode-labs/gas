defmodule Gas.Tags.EchoTag do
  @moduledoc false
  @enforce_keys [:loc, :object]
  defstruct [:loc, :object]

  @behaviour Gas.Tag

  @impl true
  def parse("echo", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, object, [{:end, _}]} <- Gas.Object.parse(tokens) do
      {:ok, %__MODULE__{loc: loc, object: object}, context}
    else
      {:error, reason, _rest, loc} -> {:error, reason, loc}
      error -> error
    end
  end

  defimpl Gas.Renderable do
    def render(tag, context, options) do
      {:ok, value, context} =
        Gas.Argument.render(tag.object.argument, context, tag.object.filters, options)

      {[value], context}
    end
  end
end
