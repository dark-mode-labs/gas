defprotocol Gas.Renderable do
  @spec render(t, Gas.Context.t(), Keyword.t()) ::
          {binary | iolist | [t], Gas.Context.t()}
  def render(value, context, options)
end
