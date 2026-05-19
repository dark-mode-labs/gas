defmodule Gas do
  @moduledoc """
  Gas is a fork of [Solid](https://github.com/edgurgel/solid), an implementation in Elixir of the [Liquid](https://shopify.github.io/liquid/) template language with strict parsing.
  Gas expands on the Solid foundation and focuses primarily on having full parity with the Liquid convention and specification.
  """

  alias Gas.{Argument, Context, Object, Parser, Text}
  alias Gas.Tags.AssignTag

  @type errors :: [error]
  @type error ::
          Gas.UndefinedVariableError.t()
          | Gas.UndefinedFilterError.t()
          | Gas.ArgumentError.t()
          | Gas.WrongFilterArityError.t()
          | Gas.FileSystem.Error.t()
          | Gas.TemplateError.t()

  defmodule Template do
    @moduledoc """
    Structure that holds the compiled AST of the parsed liquid
    """
    @type t :: %__MODULE__{parsed_template: Parser.parse_tree()}

    @enforce_keys [:parsed_template]
    defstruct [:parsed_template]
  end

  defmodule RenderError do
    @type t :: %__MODULE__{message: binary, errors: Gas.errors(), result: iolist}
    defexception [:message, :errors, :result]

    @impl true
    def message(exception) do
      message = "#{length(exception.errors)} error(s) found while rendering"

      errors =
        Enum.map_join(exception.errors, "\n", &Exception.message/1)

      message <> "\n" <> errors
    end
  end

  defmodule ParserError do
    @moduledoc false
    @type t :: %__MODULE__{
            reason: binary,
            meta: %{line: pos_integer, column: pos_integer},
            text: binary
          }
    defexception [:reason, :meta, :text]

    @impl true
    def message(%{text: text, reason: reason, meta: %{line: line, column: column}}) do
      line_size = String.length(to_string(line))
      "#{reason}\n#{line}: #{text}\n#{String.pad_leading("^", column + line_size + 2)}"
    end
  end

  defmodule TemplateError do
    @moduledoc false
    @type t :: %__MODULE__{errors: [ParserError.t()]}
    defexception [:errors]

    @impl true
    def message(exception) do
      Enum.map_join(exception.errors, "\n", &Exception.message/1)
    end
  end

  @doc """
  It generates the compiled template

  This function returns the compiled template or raises an error. Same options as `parse/2`
  """
  def parse!(text, opts \\ []) do
    case parse(text, opts) do
      {:ok, template} -> template
      {:error, template_error} -> raise template_error
    end
  end

  @doc """
  It generates the compiled template

  This function returns `{:ok, template}` if successfully parses the template, `{:error, template_error}` otherwise

  # Options

  - `tags` - Override tags allowed during compilation. See `Gas.Tag.default_tags/0` for more information on the default set of tags

  """
  @spec parse(binary, keyword) :: {:ok, Template.t()} | {:error, TemplateError.t()}
  def parse(text, opts \\ []) do
    case Parser.parse(text, opts) do
      {:ok, parse_tree} ->
        {:ok, %Template{parsed_template: parse_tree}}

      {:error, errors} ->
        lines = String.splitter(text, "\n")

        errors =
          Enum.map(errors, fn {reason, meta} ->
            %ParserError{text: Enum.at(lines, meta[:line] - 1), reason: reason, meta: meta}
          end)

        {:error, %TemplateError{errors: errors}}
    end
  end

  def precompile(template, options \\ []) do
    with cache_module <- Keyword.get(options, :cache_module, Gas.Caching.NoCache),
         {:error, :not_found} <- cache_module.get(template),
         {file_system, instance} <-
           Keyword.get(options, :file_system, {Gas.PassThroughFileSystem, nil}),
         {:ok, text} <- file_system.read_template_file(template, instance),
         {:ok, parse_tree} <- parse(text, options),
         expanded <- Gas.Compiler.Interpolation.expand(parse_tree, options),
         folded <- Gas.Compiler.ConstantFold.run(expanded),
         merged <- Gas.Compiler.TextMerge.run(folded),
         :ok <- cache_module.put(template, merged) do
      {:ok, merged}
    else
      {:ok, %Gas.Template{} = parsed_template} -> {:ok, parsed_template}
      other -> other
    end
  end

  @doc """
  It renders the compiled template using a map with vars

  Same options as `render/3`
  """
  @spec render!(Template.t(), map, keyword) :: iolist | no_return
  def render!(%Template{} = template, hash, options \\ []) do
    case render(template, hash, options) do
      # Ignore errors here unless `strict_variables` are used
      {:ok, result, _error} ->
        result

      {:error, errors, result} ->
        raise RenderError, errors: errors, result: result
    end
  end

  @doc """
  It renders the compiled template using a map with initial vars

  ## Options

  - `file_system`: a tuple of {FileSystemModule, options}. If this option is not specified, `Gas` uses `Gas.BlankFileSystem` which returns an error when the `render` tag is used. `Gas.LocalFileSystem` can be used or a custom module may be implemented. See `Gas.FileSystem` for more details.

  - `strict_variables`: if `true`, it collects an error when a variable is referenced in the template, but not given in the map

  - `matcher_module`: a module to replace `Gas.Matcher` when resolving variables.

  ## Example

  fs = Gas.LocalFileSystem.new("/path/to/template/dir/")
  Gas.render(template, vars, [file_system: {Gas.LocalFileSystem, fs}])
  """
  @spec render(Template.t(), map, keyword) ::
          {:ok, result :: iolist, errors} | {:error, errors, partial_result :: iolist}
  @spec render(Parser.parse_tree(), Context.t(), keyword) :: {iolist, Context.t()}
  def render(template_or_text, values, options \\ [])

  def render(%Template{parsed_template: parse_tree}, %Context{} = context, options) do
    context = %{
      context
      | matcher_module: Keyword.get(options, :matcher_module, context.matcher_module),
        scopes: Keyword.get(options, :scopes, context.scopes),
        strict_variables: Keyword.get(options, :strict_variables, context.strict_variables)
    }

    {result, context} = render(parse_tree, context, options)

    process_result(result, context, options)
  catch
    {exp, result, context} when exp in [:break_exp, :continue_exp] ->
      process_result(result, context, options)
  end

  def render(%Template{} = template, hash, options) do
    matcher_module = Keyword.get(options, :matcher_module, Gas.Matcher)
    context = %Context{counter_vars: hash, matcher_module: matcher_module}

    render(template, context, options)
  end

  def render(text, %Context{} = context, options) do
    render_list(List.wrap(text), context, options, [])
  end

  defp render_list([], context, _options, acc), do: {Enum.reverse(acc), context}

  defp render_list([entry | rest], context, options, acc) do
    {result, context} = do_render(entry, context, options)
    render_list(rest, context, options, [result | acc])
  catch
    {:break_exp, result, context} ->
      throw({:break_exp, Enum.reverse([result | acc]), context})

    {:continue_exp, result, context} ->
      throw({:continue_exp, Enum.reverse([result | acc]), context})
  end

  defp do_render(%Text{text: text}, context, _options), do: {text, context}

  defp do_render(%Object{argument: arg, filters: filters}, context, options) do
    {:ok, result, context} = Argument.render(arg, context, filters, options)
    {result, context}
  end

  defp do_render(
         %AssignTag{argument: target, object: %Object{argument: arg, filters: filters}},
         context,
         options
       ) do
    {:ok, value, context} = Argument.get(arg, context, filters, options)
    {[], %{context | vars: Map.put(context.vars, to_string(target), value)}}
  end

  defp do_render(tag, context, options) when is_struct(tag) do
    {result, context} = Gas.Renderable.render(tag, context, options)

    render(result, context, options)
  end

  defp do_render(iolist, context, _options) do
    {iolist, context}
  end

  defp process_result(result, context, _options) do
    if strict_errors?(context) do
      {:error, Enum.reverse(context.errors), result}
    else
      {:ok, result, Enum.reverse(context.errors)}
    end
  end

  defp strict_errors?(%Context{errors: errors, strict_variables: strict_variables}) do
    {variable_errors, filter_errors} =
      Enum.split_with(errors, &match?(%Gas.UndefinedVariableError{}, &1))

    (strict_variables == true && variable_errors != []) || filter_errors != []
  end
end
