import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lupa
import numpy as np
import matplotlib.pyplot as plt
from mpl_toolkits.mplot3d.art3d import Poly3DCollection
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

def render_spire_stairs(parts, out_path='tools/view_spire_stairs.png'):
    # Only include Spire parts and mountain rock (filter out base island slabs)
    focused = [p for p in parts if ('Spire' in p['name'] or 'Stair' in p['name'] or 'Astrolabe' in p['name'] or 'Flight' in p['name'] or 'Landing' in p['name']) and -2 <= p['pos'][1] <= 32]

    fig = plt.figure(figsize=(12, 10), dpi=120)
    ax = fig.add_subplot(111, projection='3d')
    ax.set_facecolor('#080a14')

    for p in focused:
        px, py, pz = p['pos']
        sx, sy, sz = p['size']
        c = p['color']
        alpha = max(0.4, 1.0 - p['transparency'])

        x = [px - sx/2, px + sx/2]
        y = [pz - sz/2, pz + sz/2]
        z = [py - sy/2, py + sy/2]

        faces = [
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[0], y[1], z[0]]],
            [[x[0], y[0], z[1]], [x[1], y[0], z[1]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[1], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[0], y[1], z[0]], [x[0], y[1], z[1]], [x[0], y[0], z[1]]],
            [[x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[1], y[0], z[1]]],
        ]
        poly = Poly3DCollection(faces, facecolors=c, alpha=alpha, edgecolors='#333344', linewidths=0.5)
        ax.add_collection3d(poly)

    ax.view_init(elev=22, azim=130)
    ax.set_xlim(28, 68)
    ax.set_ylim(-68, -32)
    ax.set_zlim(0, 25)
    ax.set_xlabel('X (Studs)', color='white')
    ax.set_ylabel('Z (Studs)', color='white')
    ax.set_zlabel('Y (Height)', color='white')
    ax.set_title("Stargazer Spire - Continuous Switchback Staircase", color='white', fontsize=14, pad=12)
    ax.tick_params(colors='white')

    plt.tight_layout()
    plt.savefig(out_path, dpi=120)
    plt.close()
    print(f'Saved spire stairs view to {out_path}')

def render_obby(parts, out_path='tools/view_obby.png'):
    # Only include Obby and Peak parts
    focused = [p for p in parts if ('Obby' in p['name'] or 'Peak' in p['name'] or 'Treasure' in p['name']) and -2 <= p['pos'][1] <= 32]

    fig = plt.figure(figsize=(12, 10), dpi=120)
    ax = fig.add_subplot(111, projection='3d')
    ax.set_facecolor('#080a14')

    for p in focused:
        px, py, pz = p['pos']
        sx, sy, sz = p['size']
        c = p['color']
        alpha = max(0.4, 1.0 - p['transparency'])

        x = [px - sx/2, px + sx/2]
        y = [pz - sz/2, pz + sz/2]
        z = [py - sy/2, py + sy/2]

        faces = [
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[0], y[1], z[0]]],
            [[x[0], y[0], z[1]], [x[1], y[0], z[1]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[1], y[0], z[0]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[1], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[0], y[1], z[1]]],
            [[x[0], y[0], z[0]], [x[0], y[1], z[0]], [x[0], y[1], z[1]], [x[0], y[0], z[1]]],
            [[x[1], y[0], z[0]], [x[1], y[1], z[0]], [x[1], y[1], z[1]], [x[1], y[0], z[1]]],
        ]
        poly = Poly3DCollection(faces, facecolors=c, alpha=alpha, edgecolors='#334466', linewidths=0.5)
        ax.add_collection3d(poly)

    ax.view_init(elev=20, azim=45)
    ax.set_xlim(-15, 15)
    ax.set_ylim(-225, -80)
    ax.set_zlim(0, 30)
    ax.set_xlabel('X (Studs)', color='white')
    ax.set_ylabel('Z (Studs)', color='white')
    ax.set_zlabel('Y (Height)', color='white')
    ax.set_title("Floating Obby - Verified Continuous Jump Trajectory", color='white', fontsize=14, pad=12)
    ax.tick_params(colors='white')

    plt.tight_layout()
    plt.savefig(out_path, dpi=120)
    plt.close()
    print(f'Saved obby view to {out_path}')

if __name__ == '__main__':
    parts = load_world()
    render_spire_stairs(parts)
    render_obby(parts)
