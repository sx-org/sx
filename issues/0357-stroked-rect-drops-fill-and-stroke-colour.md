# 0357 — a stroked rect loses its fill and draws the border in the fill colour

Status: OPEN — needs a vertex-format change (a second colour per
vertex) plus the three shaders. Filed 2026-07-25.

## Symptom

`RenderContext.add_stroked_rect(frame, fill, stroke, width, radius)`
and, through it, `Mod.border` do not draw what they name:

- the FILL is lost — the interior renders transparent, not `fill`;
- the border is drawn in the FILL colour; `stroke` never reaches the GPU.

So a chip declared as "moss background, line border" comes out as a
hollow ring in moss, and a chip declared as "transparent background,
line border" — the ordinary spelling for an unselected segmented-control
segment — renders nothing at all.

This contradicts the documented contract in modifier.sx, whose
example pins "a border renders even without a fill; the stroke sits on
the box" (examples/ui/1911-ui-mod-chip-card.sx `stroked`), and the
example passes only because it asserts on the render TREE, never on
pixels.

Reported by Agra from the sudoku game: its number-pad keys came out as
hollow outlines instead of filled caps, and its unselected difficulty
chips were invisible.

## Cause

Two layers, one missing channel.

`RenderNode` carries `stroke_color`, and `add_stroked_rect` fills it in.
But `UIRenderer.process` forwards only the fill:

    case .rounded_rect: {
        self.push_quad(node.frame, node.fill_color, node.corner_radius, node.stroke_width);
    }

The vertex is 12 floats — pos(2), uv(2), colour(4), params(4) where
params = (radius, border_width, w, h). There is no slot for a second
colour, so `stroke_color` is dropped at the boundary.

The fragment shader then treats a non-zero border as "ring INSTEAD of
fill" rather than "ring ON the fill":

    if (border > 0.0) {
        float inner = roundedBoxSDF(center, half_size - vec2(border), max(mode - border, 0.0));
        float border_alpha = smoothstep(-aa, aa, inner);
        alpha = alpha * max(border_alpha, 0.0);   // interior masked OUT
    }
    FragColor = vec4(vColor.rgb, vColor.a * alpha);

`vColor` is the fill, so the surviving ring wears the fill's colour.

## Fix sketch

Carry the stroke as a second per-vertex colour:

- `UI_VERTEX_FLOATS` 12 → 16, `UI_VERTEX_BYTES` 48 → 64, a fifth
  attribute at offset 48;
- `write_vertex` / `push_quad` / `push_quad_uv` take the stroke colour;
- all three shaders (desktop GL, WebGL2/ES, Metal) gain `aStroke` and
  composite `mix(fill, stroke, border_alpha)` over the SDF alpha instead
  of masking the interior away.

Pixel goldens under examples/ui/pixels/ will need regenerating for any
scene using a border.

## Workaround in the meantime

Compose the border at the call site: a rounded rect in the border
colour with the filled rect inset inside it. The sudoku game does this
for its keys and chips; that code reverts to `Mod.border` once this
lands.
