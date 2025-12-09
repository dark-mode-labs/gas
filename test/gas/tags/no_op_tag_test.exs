defmodule Gas.Tags.NoOpTagTest do
  use ExUnit.Case, async: true
  alias Gas.Tags.NoOpTag
  alias Gas.{Lexer, ParserContext}
  alias Gas.Parser.Loc

  defp parse(template) do
    context = %ParserContext{rest: template, line: 1, column: 1, mode: :normal}

    with {:ok, tag, context} <- Lexer.tokenize_tag_start(context) do
      NoOpTag.parse(tag, %Loc{line: 1, column: 1}, context)
    end
  end

  describe "parse/2" do
    test "basic" do
      Enum.each(["comment", "doc"], fn tag ->
        template = ~s<{% #{tag} %} {{ yo }} {% end#{tag} %}>

        assert parse(template) ==
                 {:ok, %NoOpTag{loc: %Loc{line: 1, column: 1}},
                  %ParserContext{
                    rest: "",
                    line: 1,
                    column: String.length(template) + 1,
                    mode: :normal
                  }}
      end)
    end

    test "error" do
      Enum.each(["comment", "doc"], fn tag ->
        template = ~s<{% #{tag} %}>

        assert parse(template) ==
                 {:error, "#{tag} tag not terminated",
                  %{column: String.length(template) + 1, line: 1}}
      end)
    end
  end

  describe "Renderable impl" do
    test "does nothing" do
      Enum.each(["comment", "doc"], fn tag ->
        template = ~s<{% #{tag} %} {{ yo }} #{tag} {% end#{tag} %}>
        context = %Gas.Context{}

        {:ok, tag, _rest} = parse(template)

        assert Gas.Renderable.render(tag, context, []) == {[], %Gas.Context{}}
      end)
    end
  end
end
