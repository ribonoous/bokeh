
define [
  "underscore",
  "backbone",
  "kiwi",
  "./build_views",
  "./plot_utils",
  "./continuum_view",
  "./has_parent",
  "./canvas",
  "./layout_box",
  "./solver",
  "./cartesian_frame",
  "./plot_template"
  "renderer/properties",
  "tool/active_tool_manager",
], (_, Backbone, kiwi, build_views, plot_utils, ContinuumView, HasParent, Canvas, LayoutBox, Solver, CartesianFrame, plot_template, Properties, ActiveToolManager) ->

  line_properties = Properties.line_properties
  text_properties = Properties.text_properties

  Expr = kiwi.Expression
  Constraint = kiwi.Constraint
  EQ = kiwi.Operator.Eq
  LE = kiwi.Operator.Le
  GE = kiwi.Operator.Ge

  class PlotView extends ContinuumView.View
    className: "bokeh plotview plotarea"
    template: plot_template

    view_options: () ->
      _.extend({plot_model: @model, plot_view: @}, @options)

    pause: () ->
      @is_paused = true

    unpause: () ->
      @is_paused = false
      @request_render()

    request_render: () ->
      if not @is_paused
        @throttled_render(true)
      return

    initialize: (options) ->
      super(options)
      @pause()

      @model.initialize_layout(@model.solver)

      # compat, to be removed
      @frame = @mget('frame')
      @x_range = @frame.get('x_ranges')['default']
      @y_range = @frame.get('y_ranges')['default']
      @xmapper = @frame.get('x_mappers')['default']
      @ymapper = @frame.get('y_mappers')['default']

      template_data = {
        button_bar: @mget('button_bar')
      }
      html = @template(template_data)
      @$el.html(html)

      @canvas = @mget('canvas')
      @canvas_view = new @canvas.default_view({'model': @canvas})

      @$('.bokeh_canvas_wrapper_outer').prepend(@canvas_view.el)
      @canvas_view.render()

      @throttled_render = plot_utils.throttle_animation(@render, 15)

      @outline_props = new line_properties(@, {}, 'outline_')
      @title_props = new text_properties(@, {}, 'title_')

      @renderers = {}
      @tools = {}

      @eventSink = _.extend({}, Backbone.Events)
      @atm = new ActiveToolManager(@eventSink)
      @levels = {}
      for level in plot_utils.LEVELS
        @levels[level] = {}
      @build_levels()
      @atm.bind_bokeh_events()
      @bind_bokeh_events()
      @model.add_constraints(@canvas.solver)
      @listenTo(@canvas.solver, 'layout_update', @request_render)

      @unpause()
      @request_render()
      return this

    map_to_screen: (x, x_units, y, y_units) ->
      @frame.map_to_screen(x, x_units, y, y_units, @canvas)

    map_from_screen: (sx, sy, units) ->
      @frame.map_from_screen(sx, sy, units, @canvas)

    update_range: (range_info) ->
      if not range_info?
        range_info = @initial_range_info
      @pause()
      @x_range.set(range_info.xr)
      @y_range.set(range_info.yr)
      @unpause()

    build_levels: () ->
      # need to separate renderer/tool creation from event binding
      # because things like box selection overlay needs to bind events
      # on the select tool
      #
      # should only bind events on NEW views and tools
      old_renderers = _.keys(@renderers)
      views = build_views(@renderers, @mget('renderers'), @view_options())
      renderers_to_remove = _.difference(old_renderers, _.pluck(@mget('renderers'), 'id'))
      for id_ in renderers_to_remove
        delete @levels.glyph[id_]
      tools = build_views(@tools, @mget('tools'), @view_options())
      for v in views
        level = v.mget('level')
        @levels[level][v.model.id] = v
        v.bind_bokeh_events()
      for t in tools
        level = t.mget('level')
        @levels[level][t.model.id] = t
        t.bind_bokeh_events()
      return this

    bind_bokeh_events: () ->
      @listenTo(@mget('frame').get('x_range'), 'change', @request_render)
      @listenTo(@mget('frame').get('y_range'), 'change', @request_render)
      @listenTo(@model, 'change:renderers', @build_levels)
      @listenTo(@model, 'change:tool', @build_levels)
      @listenTo(@model, 'change', @request_render)
      @listenTo(@model, 'destroy', () => @remove())

    set_initial_range : () ->
      #check for good values for ranges before setting initial range
      range_vals = [@x_range.get('start'), @x_range.get('end'),
        @y_range.get('start'), @y_range.get('end')]
      good_vals = _.map(range_vals, (val) -> val? and not _.isNaN(val))
      good_vals = _.all(good_vals)
      if good_vals
        @initial_range_info = {
          xr: { start: @x_range.get('start'), end: @x_range.get('end') }
          yr: { start: @y_range.get('start'), end: @y_range.get('end') }
        }

    render: (force_canvas=false) ->
      super()
      @canvas_view.render(force_canvas)

      ctx = @canvas_view.ctx

      frame = @model.get('frame')
      canvas = @model.get('canvas')

      for k, v of @renderers
        if v.model.update_layout?
          v.model.update_layout(v, @canvas.solver)

      title = @mget('title')
      if title
        @title_props.set(@canvas_view.ctx, {})
        th = ctx.measureText(@mget('title')).ascent + @model.get('title_standoff')
        if th != @model.title_panel.get('height')
          @model.title_panel.set('height', th)

      @model.get('frame').set('width', canvas.get('width'))
      @model.get('frame').set('height', canvas.get('height'))

      @canvas.solver.update_variables(false)

      # TODO (bev) OK this sucks, but the event from the solver update doesn't
      # reach the frame in time (sometimes) so force an update here for now
      @model.get('frame')._update_mappers()

      if not @initial_range_info?
        @set_initial_range()

      frame_box = [
        @canvas.vx_to_sx(@frame.get('left')),
        @canvas.vy_to_sy(@frame.get('top')),
        @frame.get('width'),
        @frame.get('height'),
      ]

      @_map_hook()
      @_paint_empty(ctx, frame_box)

      if @outline_props.do_stroke
        @outline_props.set(ctx, {})
        ctx.strokeRect.apply(ctx, frame_box)

      @_render_levels(ctx, ['image', 'underlay', 'glyph'], frame_box)
      @_render_levels(ctx, ['overlay', 'annotation', 'tool'])

      if title
        sx = @canvas.vx_to_sx(@canvas.get('width')/2)
        sy = @canvas.vy_to_sy(@model.title_panel.get('bottom') + @model.get('title_standoff'))
        @title_props.set(ctx, {})
        ctx.fillText(title, sx, sy)

    _render_levels: (ctx, levels, clip_region) ->
      ctx.save()

      if clip_region?
        ctx.beginPath()
        ctx.rect.apply(ctx, clip_region)
        ctx.clip()
        ctx.beginPath()

      for level in levels
        renderers = @levels[level]
        for k, v of renderers
          v.render()

      ctx.restore()

    _map_hook: () ->

    _paint_empty: (ctx, frame_box) ->
      ctx.fillStyle = @mget('border_fill')
      ctx.fillRect(0, 0,  @canvas_view.mget('canvas_width'), @canvas_view.mget('canvas_height')) # TODO
      ctx.fillStyle = @mget('background_fill')
      ctx.fillRect.apply(ctx, frame_box)

  class Plot extends HasParent
    type: 'Plot'
    default_view: PlotView

    initialize: (attrs, options) ->
      super(attrs, options)

      canvas = new Canvas.Model({
        map: @use_map ? false
        canvas_width: @get('plot_width'),
        canvas_height: @get('plot_height'),
        hidpi: @get('hidpi')
        solver: new Solver()
      })
      @set('canvas', canvas)

      @solver = canvas.get('solver')

      for r in @get('renderers')
        r.set('parent', @)

    initialize_layout: (solver) ->
      canvas = @get('canvas')
      frame = new CartesianFrame.Model({
        x_range: @get('x_range'),
        x_mapper_type: @get('x_mapper_type'),
        y_range: @get('y_range'),
        y_mapper_type: @get('y_mapper_type'),
        solver: solver
      })
      @set('frame', frame)

      # TODO (bev) titles should probably be a proper guide, then they could go
      # on any side, this will do to get the PR merged
      @title_panel = new LayoutBox.Model({solver: solver})
      LayoutBox.Collection.add(@title_panel)
      @title_panel._anchor = @title_panel._bottom
      elts = @get('above')
      elts.push(@title_panel)
      @set('above', elts)

    add_constraints: (solver) ->
      min_border_top    = @get('min_border_top')    ? @get('min_border')
      min_border_bottom = @get('min_border_bottom') ? @get('min_border')
      min_border_left   = @get('min_border_left')   ? @get('min_border')
      min_border_right  = @get('min_border_right')  ? @get('min_border')

      do_side = (solver, min_size, side, cnames, dim, op) =>
        canvas = @get('canvas')
        frame = @get('frame')
        box = new LayoutBox.Model({solver: solver})
        c0 = '_'+cnames[0]
        c1 = '_'+cnames[1]
        solver.add_constraint(new Constraint(new Expr(box['_'+dim], -min_size), GE), kiwi.Strength.strong)
        solver.add_constraint(new Constraint(new Expr(frame[c0], [-1, box[c1]]), EQ))
        solver.add_constraint(new Constraint(new Expr(box[c0], [-1, canvas[c0]]), EQ))
        last = frame
        elts = @get(side)
        for r in elts
          if r.get('location') ? 'auto' == 'auto'
            r.set('location', side, {'silent' : true})
          if r.initialize_layout?
            r.initialize_layout(solver)
          solver.add_constraint(new Constraint(new Expr(last[c0], [-1, r[c1]]), EQ), kiwi.Strength.strong)
          last = r
        padding = new LayoutBox.Model({solver: solver})
        solver.add_constraint(new Constraint(new Expr(last[c0], [-1, padding[c1]]), EQ), kiwi.Strength.strong)
        solver.add_constraint(new Constraint(new Expr(padding[c0], [-1, canvas[c0]]), EQ), kiwi.Strength.strong)

      do_side(solver, min_border_top, 'above', ['top', 'bottom'], 'height', LE)
      do_side(solver, min_border_bottom, 'below', ['bottom', 'top'], 'height', GE)
      do_side(solver, min_border_left, 'left', ['left', 'right'], 'width', GE)
      do_side(solver, min_border_right, 'right', ['right', 'left'], 'width', LE)

    add_renderers: (new_renderers) ->
      renderers = @get('renderers')
      renderers = renderers.concat(new_renderers)
      @set('renderers', renderers)

    parent_properties: [
      'background_fill',
      'border_fill',
      'min_border',
      'min_border_top',
      'min_border_bottom'
      'min_border_left'
      'min_border_right'
    ]

    defaults: () ->
      return {
        button_bar: true
        renderers: [],
        tools: [],
        h_symmetry: true,
        v_symmetry: false,
        x_mapper_type: 'auto',
        y_mapper_type: 'auto',
        plot_width: 600,
        plot_height: 600,
        title: 'Plot',
        above: [],
        below: [],
        left: [],
        right: []
      }

    display_defaults: () ->
      return {
        hidpi: true,
        background_fill: "#fff",
        border_fill: "#fff",
        min_border: 40,

        title_standoff: 8,
        title_text_font: "helvetica",
        title_text_font_size: "20pt",
        title_text_font_style: "normal",
        title_text_color: "#444444",
        title_text_alpha: 1.0,
        title_text_align: "center",
        title_text_baseline: "alphabetic"

        outline_line_color: '#aaaaaa'
        outline_line_width: 1
        outline_line_alpha: 1.0
        outline_line_join: 'miter'
        outline_line_cap: 'butt'
        outline_line_dash: []
        outline_line_dash_offset: 0
      }

  class Plots extends Backbone.Collection
     model: Plot

  return {
    "Model": Plot,
    "Collection": new Plots(),
    "View": PlotView,
  }
