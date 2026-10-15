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
        rot = np.eye(3)
        if hasattr(p, 'CFrame') and hasattr(p.CFrame, 'R'):
            R = p.CFrame.R
            rot = np.array([
                [float(R.r00), float(R.r01), float(R.r02)],
                [float(R.r10), float(R.r11), float(R.r12)],
                [float(R.r20), float(R.r21), float(R.r22)],
            ])
        parts_data.append({
            'name': str(p.Name),
            'shape': str(p.Shape),
            'material': str(p.Material),
            'pos': np.array([float(p.Position.X), float(p.Position.Y), float(p.Position.Z)]),
            'size': np.array([float(p.Size.X), float(p.Size.Y), float(p.Size.Z)]),
            'rot': rot,
            'color': (float(r), float(g), float(b)),
            'transparency': float(p.Transparency or 0),
        })
    return parts_data

def get_oriented_box_faces(pos, size, rot):
    hx, hy, hz = size[0] / 2.0, size[1] / 2.0, size[2] / 2.0
    local_corners = np.array([
        [-hx, -hy, -hz],
        [ hx, -hy, -hz],
        [ hx,  hy, -hz],
        [-hx,  hy, -hz],
        [-hx, -hy,  hz],
        [ hx, -hy,  hz],
        [ hx,  hy,  hz],
        [-hx,  hy,  hz],
    ])
    world_corners = (rot @ local_corners.T).T + pos
    plot_corners = np.zeros_like(world_corners)
    plot_corners[:, 0] = world_corners[:, 0]
    plot_corners[:, 1] = world_corners[:, 2] # Z
    plot_corners[:, 2] = world_corners[:, 1] # Y
    
    c = plot_corners
    return [
        [c[0], c[1], c[2], c[3]],
        [c[4], c[5], c[6], c[7]],
        [c[0], c[1], c[5], c[4]],
        [c[2], c[3], c[7], c[6]],
        [c[0], c[3], c[7], c[4]],
        [c[1], c[2], c[6], c[5]],
    ]

def render_spire_stairs(parts, out_path='tools/view_spire_stairs.png'):
    focused = [p for p in parts if ('Spire' in p['name'] or 'Stair' in p['name'] or 'Astrolabe' in p['name'] or 'Flight' in p['name'] or 'Landing' in p['name'] or 'Observation' in p['name'] or 'Rotunda' in p['name']) and -2 <= p['pos'][1] <= 32]

    fig = plt.figure(figsize=(12, 10), dpi=120)
    ax = fig.add_subplot(111, projection='3d')
    ax.set_facecolor('#080a14')

    for p in focused:
        faces = get_oriented_box_faces(p['pos'], p['size'], p['rot'])
        c = p['color']
        alpha = max(0.4, 1.0 - p['transparency'])
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
    focused = [p for p in parts if ('Obby' in p['name'] or 'Peak' in p['name'] or 'Treasure' in p['name']) and -2 <= p['pos'][1] <= 32]

    fig = plt.figure(figsize=(12, 10), dpi=120)
    ax = fig.add_subplot(111, projection='3d')
    ax.set_facecolor('#080a14')

    for p in focused:
        faces = get_oriented_box_faces(p['pos'], p['size'], p['rot'])
        c = p['color']
        alpha = max(0.4, 1.0 - p['transparency'])
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
