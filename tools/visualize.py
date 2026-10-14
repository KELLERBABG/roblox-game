import lupa
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.collections import PatchCollection
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cleaner import clean_luau

def load_world():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    with open('tools/mock_roblox.lua', 'r', encoding='utf-8') as f:
        env_code = f.read()
    mock = lua.execute(env_code)

    with open('Visuals/World/Builder.luau', 'r', encoding='utf-8') as f:
        b_code = clean_luau(f.read())
    builder = lua.execute(b_code)
    world = builder.Build(mock.Workspace)

    with open('Visuals/World/Foliage.luau', 'r', encoding='utf-8') as f:
        f_code = clean_luau(f.read())
    foliage = lua.execute(f_code)
    foliage.PopulateSanctuary(world)

    parts_data = []
    for i in range(1, len(mock.allParts) + 1):
        p = mock.allParts[i]
        c = p.Color
        r = c.R if hasattr(c, 'R') else (c.r / 255.0 if hasattr(c, 'r') else 0.5)
        g = c.G if hasattr(c, 'G') else (c.g / 255.0 if hasattr(c, 'g') else 0.5)
        b = c.B if hasattr(c, 'B') else (c.b / 255.0 if hasattr(c, 'b') else 0.5)
        parts_data.append({
            'name': str(p.Name),
            'shape': str(p.Shape),
            'material': str(p.Material),
            'pos': np.array([float(p.Position.X), float(p.Position.Y), float(p.Position.Z)]),
            'size': np.array([float(p.Size.X), float(p.Size.Y), float(p.Size.Z)]),
            'color': (float(r), float(g), float(b)),
            'transparency': float(p.Transparency or 0),
        })
    return parts_data

def render_topdown(parts, out_path='tools/view_topdown.png'):
    fig, ax = plt.subplots(figsize=(16, 16), dpi=120)
    ax.set_facecolor('#0f111a')

    # Sort parts by Y so higher parts draw on top
    sorted_parts = sorted(parts, key=lambda p: p['pos'][1])

    for p in sorted_parts:
        px, py, pz = p['pos']
        sx, sy, sz = p['size']
        color = p['color']
        alpha = max(0.15, 1.0 - p['transparency'])

        if p['material'] == 'Neon':
            edgecolor = '#ffffff'
            linewidth = 0.8
        else:
            edgecolor = None
            linewidth = 0

        # Draw cylinder as circle if vertical, or rect
        if p['shape'] == 'Cylinder':
            # Check axis of cylinder: usually size is (length, d, d)
            rad = max(sy, sz) / 2.0
            circle = plt.Circle((px, pz), rad, facecolor=color, edgecolor=edgecolor, linewidth=linewidth, alpha=alpha)
            ax.add_patch(circle)
        elif p['shape'] == 'Ball':
            rad = max(sx, sy, sz) / 2.0
            circle = plt.Circle((px, pz), rad, facecolor=color, edgecolor=edgecolor, linewidth=linewidth, alpha=alpha)
            ax.add_patch(circle)
        else:
            # Box
            rect = plt.Rectangle((px - sx / 2.0, pz - sz / 2.0), sx, sz,
                                 facecolor=color, edgecolor=edgecolor, linewidth=linewidth, alpha=alpha)
            ax.add_patch(rect)

    # Highlight problem areas
    # 1. Altar center
    ax.plot(0, 0, 'y*', markersize=16, label='Altar Center (0,0)')
    # Draw Altar Step 1 boundary (r = 23)
    altar_circle = plt.Circle((0, 0), 23, fill=False, edgecolor='#ff5555', linestyle='--', linewidth=2, label='Altar Step 1 Rim (R=23)')
    ax.add_patch(altar_circle)

    # Annotate key landmarks
    ax.text(0, 0, 'ALTAR & MONOLITH', color='yellow', fontsize=12, fontweight='bold', ha='center', va='center')
    ax.text(58, -4, "STARGAZER SPIRE\n& ASTROLABE", color='#66ccff', fontsize=11, fontweight='bold', ha='center')
    ax.text(-52, -50, "MYSTIC GROTTO", color='#ff88cc', fontsize=11, fontweight='bold', ha='center')
    ax.text(38, 58, "ASTRAL WATERFALL", color='#55ffff', fontsize=11, fontweight='bold', ha='center')
    ax.text(0, 110, "FLOATING OBBY ->", color='#ffff55', fontsize=11, fontweight='bold', ha='center')

    # Draw camera ray corresponding to user screenshot
    ax.annotate("User Screenshot Camera", xy=(0, 0), xytext=(-35, 0),
                arrowprops=dict(facecolor='red', shrink=0.05, width=2, headwidth=8),
                color='red', fontsize=12, fontweight='bold')

    ax.set_xlim(-100, 100)
    ax.set_ylim(-100, 100)
    ax.set_xlabel('X Axis (Studs)', color='white', fontsize=12)
    ax.set_ylabel('Z Axis (Studs)', color='white', fontsize=12)
    ax.set_title("Sol's Sanctuary - Top-Down Floorplan Analysis", color='white', fontsize=16, pad=20)
    ax.tick_params(colors='white')
    ax.grid(True, linestyle=':', alpha=0.3, color='#8888aa')
    ax.legend(loc='upper right', facecolor='#1e2230', edgecolor='white', labelcolor='white')

    plt.tight_layout()
    plt.savefig(out_path, dpi=120)
    plt.close()
    print(f'Saved topdown map to {out_path}')

def render_camera_view(parts, out_path='tools/view_camera.png'):
    # Project 3D parts onto camera at cam_pos looking at target_pos
    cam_pos = np.array([-30.0, 4.5, 0.0])
    target = np.array([20.0, 4.5, -2.0])

    forward = target - cam_pos
    forward = forward / np.linalg.norm(forward)
    up = np.array([0.0, 1.0, 0.0])
    right = np.cross(forward, up)
    right = right / np.linalg.norm(right)
    cam_up = np.cross(right, forward)

    # 3D bounding box rendering via matplotlib
    from mpl_toolkits.mplot3d import Axes3D
    from mpl_toolkits.mplot3d.art3d import Poly3DCollection

    fig = plt.figure(figsize=(16, 9), dpi=120)
    ax = fig.add_subplot(111, projection='3d')
    ax.set_facecolor('#080a14')

    # Focus on the area around the altar and behind it (-25 to 70 in X, -30 to 30 in Z, 0 to 45 in Y)
    focused_parts = [p for p in parts if -30 <= p['pos'][0] <= 75 and -35 <= p['pos'][2] <= 35 and -5 <= p['pos'][1] <= 45]

    for p in focused_parts:
        px, py, pz = p['pos']
        sx, sy, sz = p['size']
        c = p['color']
        alpha = max(0.2, 1.0 - p['transparency'])

        # Draw a box representation
        x = [px - sx/2, px + sx/2]
        y = [pz - sz/2, pz + sz/2] # note: matplotlib Z is vertical, so map Roblox Y to Z
        z = [py - sy/2, py + sy/2]

        # 6 faces
        faces = [
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[0], y[1], z[0]]],
            [[x[0], y[0], z[1]], [x[1], y[0], z[1]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[0], z[1]], [x[0], y[0], z[1]]],
            [[x[0], y[1], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[0], y[1], z[0]], [x[0], y[1], z[1]], [x[0], y[0], z[1]]],
            [[x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[1], y[0], z[1]]],
        ]
        poly = Poly3DCollection(faces, facecolors=c, alpha=min(alpha, 0.8), edgecolors=c if p['material'] == 'Neon' else '#222233', linewidths=0.3)
        ax.add_collection3d(poly)

    # Set camera perspective looking from -30 along +X
    ax.view_init(elev=6, azim=185) # slightly elevated, looking along +X
    ax.set_xlim(-25, 65)
    ax.set_ylim(-30, 30)
    ax.set_zlim(0, 35)

    ax.set_xlabel('X (Studs)', color='white')
    ax.set_ylabel('Z (Studs)', color='white')
    ax.set_zlabel('Y (Height)', color='white')
    ax.set_title("3D View Along Screenshot Angle (X: -25 -> +65)", color='white', fontsize=14, pad=10)
    ax.tick_params(colors='white')

    plt.tight_layout()
    plt.savefig(out_path, dpi=120)
    plt.close()
    print(f'Saved camera view to {out_path}')

if __name__ == '__main__':
    parts = load_world()
    print(f'Loaded {len(parts)} parts.')
    render_topdown(parts)
    render_camera_view(parts)
