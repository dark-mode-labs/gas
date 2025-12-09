defmodule Gas.Tags.CaseTagTest do
  use ExUnit.Case, async: true
  alias Gas.Tags.CaseTag
  alias Gas.{Lexer, ParserContext, Renderable}
  alias Gas.Parser.Loc

  defp parse(template) do
    context = %ParserContext{rest: template, line: 1, column: 1, mode: :normal}

    with {:ok, tag_name, context} <- Lexer.tokenize_tag_start(context) do
      CaseTag.parse(tag_name, %Loc{line: 1, column: 1}, context)
    end
  end

  describe "parse/2" do
    test "case" do
      template = """
      {% case product %}
      ignored
      {% when 'shoes' %}
        Shoes
      {% when 'shirts' %}
        Shirts
      {% endcase %}
      """

      assert parse(template) ==
               {
                 :ok,
                 %CaseTag{
                   cases: [
                     {[%Gas.Literal{loc: %Loc{column: 9, line: 3}, value: "shoes"}],
                      [%Gas.Text{loc: %Loc{column: 19, line: 3}, text: "\n  Shoes\n"}]},
                     {[%Gas.Literal{loc: %Loc{column: 9, line: 5}, value: "shirts"}],
                      [%Gas.Text{loc: %Loc{column: 20, line: 5}, text: "\n  Shirts\n"}]}
                   ],
                   loc: %Loc{column: 1, line: 1},
                   argument: %Gas.Variable{
                     original_name: "product",
                     accesses: [],
                     identifier: "product",
                     loc: %Loc{column: 9, line: 1}
                   }
                 },
                 %ParserContext{
                   column: 14,
                   line: 7,
                   mode: :normal,
                   rest: "\n",
                   tags: nil
                 }
               }
    end

    test "case with unordered when and else" do
      template = """
      {% case product %}
      {% when 'shoes' %}
        Shoes
      {% else %}
        else1
      {% when 'shirts' %}
        Shirts
      {% else %}
        else2
      {% endcase %}
      """

      assert parse(template) ==
               {
                 :ok,
                 %Gas.Tags.CaseTag{
                   argument: %Gas.Variable{
                     original_name: "product",
                     accesses: [],
                     identifier: "product",
                     loc: %Loc{column: 9, line: 1}
                   },
                   cases: [
                     {
                       [
                         %Gas.Literal{
                           loc: %Loc{column: 9, line: 2},
                           value: "shoes"
                         }
                       ],
                       [
                         %Gas.Text{
                           loc: %Loc{column: 19, line: 2},
                           text: "\n  Shoes\n"
                         }
                       ]
                     },
                     {:else,
                      [
                        %Gas.Text{
                          loc: %Gas.Parser.Loc{column: 11, line: 4},
                          text: "\n  else1\n"
                        }
                      ]},
                     {
                       [
                         %Gas.Literal{
                           loc: %Loc{column: 9, line: 6},
                           value: "shirts"
                         }
                       ],
                       [
                         %Gas.Text{
                           loc: %Loc{column: 20, line: 6},
                           text: "\n  Shirts\n"
                         }
                       ]
                     },
                     {:else,
                      [
                        %Gas.Text{
                          loc: %Gas.Parser.Loc{column: 11, line: 8},
                          text: "\n  else2\n"
                        }
                      ]}
                   ],
                   loc: %Gas.Parser.Loc{column: 1, line: 1}
                 },
                 %Gas.ParserContext{
                   column: 14,
                   line: 10,
                   mode: :normal,
                   rest: "\n",
                   tags: nil
                 }
               }
    end

    test "else" do
      template = """
      {% case product %}
      {% when 'shoes' %}
        Shoes
      {% else %}
        Else
      {% endcase %}
      """

      assert parse(template) ==
               {
                 :ok,
                 %CaseTag{
                   cases: [
                     {[
                        %Gas.Literal{
                          loc: %Loc{column: 9, line: 2},
                          value: "shoes"
                        }
                      ],
                      [
                        %Gas.Text{
                          loc: %Loc{column: 19, line: 2},
                          text: "\n  Shoes\n"
                        }
                      ]},
                     {:else,
                      [
                        %Gas.Text{
                          loc: %Gas.Parser.Loc{column: 11, line: 4},
                          text: "\n  Else\n"
                        }
                      ]}
                   ],
                   loc: %Loc{column: 1, line: 1},
                   argument: %Gas.Variable{
                     original_name: "product",
                     accesses: [],
                     identifier: "product",
                     loc: %Loc{column: 9, line: 1}
                   }
                 },
                 %ParserContext{
                   column: 14,
                   line: 6,
                   mode: :normal,
                   rest: "\n"
                 }
               }
    end

    test "when with variable" do
      template = """
      {% case product %}
      {% when 'shoes' %}
        Shoes
      {% when shirt %}
        Shirts
      {% endcase %}
      """

      assert parse(template) == {
               :ok,
               %CaseTag{
                 loc: %Loc{column: 1, line: 1},
                 argument: %Gas.Variable{
                   original_name: "product",
                   loc: %Loc{column: 9, line: 1},
                   identifier: "product",
                   accesses: []
                 },
                 cases: [
                   {[
                      %Gas.Literal{
                        loc: %Loc{column: 9, line: 2},
                        value: "shoes"
                      }
                    ],
                    [
                      %Gas.Text{
                        loc: %Loc{column: 19, line: 2},
                        text: "\n  Shoes\n"
                      }
                    ]},
                   {[
                      %Gas.Variable{
                        original_name: "shirt",
                        loc: %Loc{column: 9, line: 4},
                        identifier: "shirt",
                        accesses: []
                      }
                    ],
                    [
                      %Gas.Text{
                        loc: %Loc{column: 17, line: 4},
                        text: "\n  Shirts\n"
                      }
                    ]}
                 ]
               },
               %ParserContext{
                 column: 14,
                 line: 6,
                 mode: :normal,
                 rest: "\n",
                 tags: nil
               }
             }
    end

    test "multiple options" do
      template =
        "{% case condition %}{% when 1, 2 or 3 %} its 1 or 2 or 3 {% when 3, 4 %} its 4 {% endcase %}"

      assert parse(template) == {
               :ok,
               %CaseTag{
                 cases: [
                   {
                     [
                       %Gas.Literal{loc: %Loc{column: 29, line: 1}, value: 1},
                       %Gas.Literal{loc: %Loc{column: 32, line: 1}, value: 2},
                       %Gas.Literal{loc: %Loc{column: 37, line: 1}, value: 3}
                     ],
                     [
                       %Gas.Text{loc: %Loc{column: 41, line: 1}, text: " its 1 or 2 or 3 "}
                     ]
                   },
                   {
                     [
                       %Gas.Literal{loc: %Loc{column: 66, line: 1}, value: 3},
                       %Gas.Literal{loc: %Loc{column: 69, line: 1}, value: 4}
                     ],
                     [%Gas.Text{loc: %Loc{column: 73, line: 1}, text: " its 4 "}]
                   }
                 ],
                 loc: %Loc{column: 1, line: 1},
                 argument: %Gas.Variable{
                   original_name: "condition",
                   accesses: [],
                   identifier: "condition",
                   loc: %Loc{column: 9, line: 1}
                 }
               },
               %Gas.ParserContext{
                 column: 93,
                 line: 1,
                 mode: :normal,
                 rest: "",
                 tags: nil
               }
             }
    end

    test "missing endcase" do
      template = """
      {% case product %}
      ignored
      {% when 'shoes' %}
        Shoes
      {% when 'shirts' %}
        Shirts
      """

      assert parse(template) == {:error, "Expected endcase", %{column: 1, line: 7}}
    end

    test "extra tokens on when" do
      template = """
      {% case product %}
      ignored
      {% when 'shoes' == two %}
        Shoes
      {% else true %}
        Shirts
      {% endcase %}
      """

      assert parse(template) == {:error, "Expected ',' or 'or'", %{column: 17, line: 3}}
    end

    test "extra tokens on else" do
      template = """
      {% case product %}
      ignored
      {% when 'shoes' %}
        Shoes
      {% else true %}
        Shirts
      {% endcase %}
      """

      assert parse(template) == {:error, "Unexpected token on else", %{column: 9, line: 5}}
    end

    test "extra tokens on endcase" do
      template = """
      {% case product %}
      ignored
      {% when 'shoes' %}
        Shoes
      {% else %}
        Shirts
      {% endcase true %}
      """

      assert parse(template) == {:error, "Unexpected token on endcase", %{column: 12, line: 7}}
    end

    test "unexpected character" do
      template = """
      {% case product - 1 %}
      ignored
      {% when 'shoes' == two %}
        Shoes
      {% else true %}
        Shirts
      {% endcase %}
      """

      assert parse(template) == {:error, "Unexpected character '-'", %{column: 17, line: 1}}
    end
  end

  describe "Renderable impl" do
    test "renders the right case with literal" do
      template = """
      {% case product %}
      {% when 'shoes' %}
        Shoes
      {% when 'shirts' %}
        Shirts
      {% endcase %}
      """

      context = %Gas.Context{vars: %{"product" => "shoes"}}

      {:ok, tag, _rest} = parse(template)

      assert Renderable.render(tag, context, []) ==
               {
                 [
                   %Gas.Text{
                     loc: %Gas.Parser.Loc{column: 19, line: 2},
                     text: "\n  Shoes\n"
                   }
                 ],
                 context
               }
    end

    test "renders the right case with variable" do
      template = """
      {% case product %}
      {% when 'shoes' %}
        Shoes
      {% when shirts %}
        Shirts
      {% endcase %}
      """

      context = %Gas.Context{vars: %{"product" => "shirt", "shirts" => "shirt"}}

      {:ok, tag, _rest} = parse(template)

      assert Renderable.render(tag, context, []) ==
               {[
                  %Gas.Text{
                    loc: %Loc{column: 18, line: 4},
                    text: "\n  Shirts\n"
                  }
                ], context}
    end

    test "renders multiple whens" do
      template = """
      {%- case product -%}
      {%- when 'shoes' -%}
        Shoes
      {%- when item -%}
        Shoes also
      {%- endcase -%}
      """

      context = %Gas.Context{vars: %{"product" => "shoes", "item" => "shoes"}}

      {:ok, tag, _rest} = parse(template)

      assert Renderable.render(tag, context, []) ==
               {[
                  %Gas.Text{loc: %Loc{column: 3, line: 3}, text: "Shoes"}
                ], context}
    end
  end
end
