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
    Structure that holds the compiled AST of the parsed liquid.

    `module` is set when `Gas.precompile/2` ran with `codegen: true`: the AST was
    also turned into an Elixir module and rendering dispatches to it instead of
    walking the tree.
    """
    @type t :: %__MODULE__{parsed_template: Parser.parse_tree(), module: module | nil}

    @enforce_keys [:parsed_template]
    defstruct [:parsed_template, :module]
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

  @doc """
  Reads, parses and optimises a template.

  Nothing is kept: the result is the caller's, and a compiled module is reached from the template's
  name by `compiled/1`. Reading the same name twice reads and parses it twice.

  ## Options

  - `file_system`: a `{module, options}` tuple used to read the template source.

  - `codegen`: if `true`, the AST is also compiled into an Elixir module and
    `Gas.render/3` dispatches to it. Costs compilation time here unless
    `on_codegen_miss` takes it off the render path.

  - `on_codegen_miss`: a 1-arity function given the AST of a template that has
    no compiled module yet. The template renders interpreted, and a later call
    picks up whatever the callback's own process compiled. It runs on the render
    path, so it must hand the work off rather than do it.

  - `instrument`: a 2-arity function given a rendered template's name and a
    zero-arity function to run, so a host can time each `{% render %}`.

  - `name_modules`: names each compiled module after the template's path rather
    than after the bytes of its AST. Only `precompile_all/2` sets this: see there
    for why a path is a safe name only when callees are compiled first.

  - `trees`: `name => parse tree` for templates already parsed by the pass that
    is running, so a caller reads its callee from there rather than off disk.
    `precompile_all/2` fills it as it goes; a name it does not hold is read.

  - `opaque_roots`: variable names whose values may themselves carry liquid. A
    `{% render %}` passes only the arguments its callee names, which is safe only
    when reading the callee's tree tells the whole story; handed one of these it
    can resolve names no tree shows, so nothing is trimmed. Defaults to none.

  Also accepts `parse/2`'s options.
  """
  def precompile(template, options \\ []) do
    with {file_system, instance} <-
           Keyword.get(options, :file_system, {Gas.PassThroughFileSystem, nil}),
         {:ok, text} <- file_system.read_template_file(template, instance),
         {:ok, parse_tree} <- parse(text, options),
         expanded <- Gas.Compiler.Interpolation.expand(parse_tree, options),
         folded <- Gas.Compiler.ConstantFold.run(expanded),
         merged <- Gas.Compiler.TextMerge.run(folded) do
      {:ok, maybe_codegen(merged, template, options)}
    end
  end

  @doc """
  Precompiles every template in `names`, each into a module named after its own path.

  A path is a name several callers share, so it is only safe to compile under one when nothing
  else is compiling it: gas compiles a `{% render %}` callee while building its caller, and a
  template reachable from two callers would otherwise be defined inside its own definition. This
  orders the templates by the renders they name — callees first — so every caller finds its
  callee's module already built and never compiles one.

  Returns `{name, result}` in the order they were compiled, `result` being whatever
  `precompile/2` answered. A template that renders one of its own callers cannot be ordered; the
  cycle is broken at whichever of them is reached first, and that one renders its callee by name
  at run time instead of calling it directly.

  A caller learns what its callee reads from the callee's tree, so the pass carries the trees it
  has parsed forward to the templates that render them — as an argument, ending with the pass,
  rather than in anything that outlives it.
  """
  @spec precompile_all([binary], keyword) :: [{binary, term}]
  def precompile_all(names, options \\ []) do
    options = Keyword.put(options, :name_modules, true)
    ordered = names |> callees_of(options) |> callees_first(names)

    # Forgotten before anything is built, so no caller ends up calling a module a later forget took.
    Enum.each(ordered, &forget/1)

    {built, _trees} =
      Enum.map_reduce(ordered, %{}, fn name, trees ->
        result = precompile(name, Keyword.put(options, :trees, trees))
        {{name, result}, remember(trees, name, result)}
      end)

    built
  end

  defp remember(trees, name, {:ok, %Template{parsed_template: tree}}),
    do: Map.put(trees, name, tree)

  defp remember(trees, _name, _failed), do: trees

  @doc """
  Drops the module a previous pass built for the template named `name`, so the next pass builds it
  from source again.
  """
  @spec forget(binary) :: :ok
  def forget(name) when is_binary(name), do: Gas.Compiler.Codegen.forget(name)

  @doc """
  The template `name` was compiled into, found from the name alone.

  `precompile_all/2` names each module after its path, which makes the module a function of the
  name: nothing has to hold a template to render it, so this parses nothing and keeps no AST.
  Answers `:error` when that pass has not built the module.
  """
  @spec compiled(binary) :: {:ok, Template.t()} | :error
  def compiled(name) when is_binary(name) do
    # `module_loaded/1` rather than `Code.ensure_loaded?/1`: these modules only ever exist because
    # something compiled them here, so there is no file for the code server to go looking for.
    with {:ok, module} <- Gas.Compiler.Codegen.module_for(name),
         true <- :erlang.module_loaded(module) do
      # The tree is not carried: a compiled module holds its own, and only reaches for it to
      # render a node whose value the request supplies.
      {:ok, %Template{parsed_template: [], module: module}}
    else
      _not_built -> :error
    end
  end

  # Only callees in the set are ordered against: one outside it is nobody here's to compile.
  defp callees_of(names, options) do
    given = MapSet.new(names)

    Map.new(names, fn name ->
      {name, name |> static_renders(options) |> Enum.filter(&MapSet.member?(given, &1))}
    end)
  end

  # Read straight from source: what a template renders by a fixed name is in its own text, and
  # ordering must not depend on anything already being compiled.
  defp static_renders(name, options) do
    with {file_system, instance} <-
           Keyword.get(options, :file_system, {Gas.PassThroughFileSystem, nil}),
         {:ok, text} <- file_system.read_template_file(name, instance),
         {:ok, %Template{parsed_template: tree}} <- parse(text, options) do
      tree |> Gas.Analysis.render_targets() |> Enum.filter(&is_binary/1)
    else
      _unreadable -> []
    end
  end

  defp callees_first(callees, names) do
    {ordered, _done} =
      Enum.reduce(names, {[], MapSet.new()}, &visit(&1, &2, callees, MapSet.new()))

    Enum.reverse(ordered)
  end

  defp visit(name, {ordered, done}, callees, open) do
    if MapSet.member?(done, name) or MapSet.member?(open, name) do
      {ordered, done}
    else
      {ordered, done} =
        callees
        |> Map.get(name, [])
        |> Enum.reduce({ordered, done}, &visit(&1, &2, callees, MapSet.put(open, name)))

      {[name | ordered], MapSet.put(done, name)}
    end
  end

  # `:name_modules` asks for a module called after the file. Only `precompile_all/2` sets it,
  # because a path is a shared name and lazy compilation has no order to protect it.
  defp maybe_codegen(%Template{} = template, name, options) do
    if Keyword.get(options, :codegen, false) do
      options =
        if Keyword.get(options, :name_modules, false),
          do: Keyword.put(options, :name, name),
          else: options

      case Gas.Compiler.Codegen.fetch_or_defer(template.parsed_template, %{}, options) do
        {:ok, module} -> %{template | module: module}
        _deferred_or_error -> template
      end
    else
      template
    end
  end

  # A module is compiled for the default matcher, scopes and lax variables; anything else is the
  # interpreter's to render, and choosing between them here is the one place that holds both. A
  # template carrying no tree has only its module, which says so itself rather than render blank.
  defp compiled_for?(%Context{matcher_module: Gas.Matcher, strict_variables: false} = context, _),
    do: context.scopes == Context.default_scopes()

  defp compiled_for?(_context, []), do: true
  defp compiled_for?(_context, _tree), do: false

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

  def render(
        %Template{parsed_template: parse_tree, module: module},
        %Context{} = context,
        options
      ) do
    context = %{
      context
      | matcher_module: Keyword.get(options, :matcher_module, context.matcher_module),
        scopes: Keyword.get(options, :scopes, context.scopes),
        strict_variables: Keyword.get(options, :strict_variables, context.strict_variables)
    }

    {result, context} =
      if module && compiled_for?(context, parse_tree) do
        {out, rendered} = module.render(context, options)

        # A filter guard has no context in reach to record its error on, so it leaves it for the
        # render to collect. Collected once, here, rather than by every module a page reaches.
        {out, Gas.Compiler.Runtime.absorb_filter_errors(rendered)}
      else
        render(parse_tree, context, options)
      end

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
  catch
    {:gas_loop_signal, kind, result, ctx, acc} ->
      throw({kind, Enum.reverse([result | acc]), ctx})
  end

  defp render_list([], context, _options, acc), do: {Enum.reverse(acc), context}

  defp render_list([entry | rest], context, options, acc) do
    {result, context} = do_render(entry, context, options)
    render_list(rest, context, options, [result | acc])
  catch
    {:break_exp, result, context} ->
      throw({:gas_loop_signal, :break_exp, result, context, acc})

    {:continue_exp, result, context} ->
      throw({:gas_loop_signal, :continue_exp, result, context, acc})
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
