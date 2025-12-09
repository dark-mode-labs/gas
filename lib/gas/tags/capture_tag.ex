defmodule Gas.Tags.CaptureTag do
  @moduledoc """
  capture tag
  """
  alias Gas.{Argument, Parser}

  @type t :: %__MODULE__{
          loc: Parser.Loc.t(),
          argument: Argument.t(),
          body: [Parser.entry()]
        }

  @enforce_keys [:loc, :argument, :body]
  defstruct [:loc, :argument, :body]

  @behaviour Gas.Tag

  @impl true
  def parse("capture", loc, context) do
    with {:ok, tokens, context} <- Gas.Lexer.tokenize_tag_end(context),
         {:ok, argument, [{:end, _}]} <- Argument.parse(tokens),
         {:ok, body, _tag, _tokens, context} <-
           Parser.parse_until(context, "endcapture", "Expected endcapture") do
      {:ok, %__MODULE__{loc: loc, argument: argument, body: body}, context}
    else
      {:ok, _, tokens} -> {:error, "Unexpected token", Parser.meta_head(tokens)}
      error -> error
    end
  end

  defimpl Gas.Renderable do
    def render(tag, context, options) do
      {captured, context} = Gas.render(tag.body, context, options)

      context = %{
        context
        | vars: Map.put(context.vars, to_string(tag.argument), IO.iodata_to_binary(captured))
      }

      {[], context}
    end
  end

  defimpl Gas.Block do
    def blank?(_), do: true
  end
end
