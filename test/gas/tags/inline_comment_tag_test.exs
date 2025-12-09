defmodule Gas.Tags.InlineCommenTagTest do
  use ExUnit.Case, async: true
  alias Gas.{Lexer, ParserContext}
  alias Gas.Tags.InlineCommentTag
  alias Gas.Parser.Loc

  defp parse(template) do
    context = %ParserContext{rest: template, line: 1, column: 1, mode: :normal}

    with {:ok, "#", context} <- Lexer.tokenize_tag_start(context) do
      InlineCommentTag.parse("#", %Loc{line: 1, column: 1}, context)
    end
  end

  describe "parse/2" do
    test "basic" do
      template = ~s<{% # a comment $ %} {{ yo }}>

      assert parse(template) == {
               :ok,
               %InlineCommentTag{loc: %Loc{column: 1, line: 1}},
               %ParserContext{column: 20, line: 1, mode: :normal, rest: " {{ yo }}"}
             }
    end

    test "empty" do
      template = ~s<{%#%} {{ yo }}>

      assert parse(template) == {
               :ok,
               %Gas.Tags.InlineCommentTag{
                 loc: %Loc{column: 1, line: 1}
               },
               %Gas.ParserContext{
                 column: 6,
                 line: 1,
                 mode: :normal,
                 rest: " {{ yo }}"
               }
             }
    end

    test "multiline" do
      template = """
      {% # a comment

         # another comment

        %}
      {{ yo }}
      """

      assert parse(template) == {
               :ok,
               %Gas.Tags.InlineCommentTag{
                 loc: %Loc{column: 1, line: 1}
               },
               %Gas.ParserContext{
                 column: 5,
                 line: 5,
                 mode: :normal,
                 rest: "\n{{ yo }}\n"
               }
             }
    end

    test "whitespace control" do
      template = """
      {%- # a comment

         # another comment

        -%}
      {{ yo }}
      """

      assert parse(template) == {
               :ok,
               %Gas.Tags.InlineCommentTag{
                 loc: %Loc{column: 1, line: 1}
               },
               %Gas.ParserContext{
                 column: 1,
                 line: 6,
                 mode: :normal,
                 rest: "{{ yo }}\n"
               }
             }
    end
  end

  describe "Renderable impl" do
    test "does nothing" do
      template = ~s<{% # a comment $ %} {{ yo }}>
      context = %Gas.Context{}

      {:ok, tag, _rest} = parse(template)

      assert Gas.Renderable.render(tag, context, []) == {[], %Gas.Context{}}
    end
  end
end
