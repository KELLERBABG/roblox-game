import re

def clean_luau(code):
    lines = code.splitlines()
    out = []
    for line in lines:
        if line.strip().startswith('--!strict'):
            continue
        # Remove casts e.g. :: Folder, :: BasePart?
        line = re.sub(r'::\s*[^,\)\n]+', '', line)
        # Function return type: e.g. ): () or ): Folder
        line = re.sub(r'\):\s*\(\)', ')', line)
        line = re.sub(r'\):\s*[A-Za-z0-9_.]+(\?)?', ')', line)
        # Table type in params: e.g. props: { [string]: any }
        line = re.sub(r':\s*\{\s*\[[^\]]+\]\s*:\s*[^}]+\}', '', line)
        # Parameter or variable type: e.g. targetParent: Instance?, ...
        # Type annotations are followed by comma, closing paren, '=', or end-of-line
        line = re.sub(r'(\b\w+)\s*:\s*[A-Za-z0-9_.]+(\?)?(?=\s*[,)=\n]|\s*$)', r'\1', line)
        # Compound operators
        line = re.sub(r'(\b\w+)\s*\+=\s*([^;\n]+)', r'\1 = \1 + (\2)', line)
        line = re.sub(r'(\b\w+)\s*-=\s*([^;\n]+)', r'\1 = \1 - (\2)', line)
        # Ternary: if A then B else C
        m = re.search(r'\bif\s+(.+?)\s+then\s+(.+?)\s+else\s+(.+)', line)
        if m:
            cond, t, f = m.group(1), m.group(2), m.group(3)
            trailing = ''
            if f.endswith(','):
                f = f[:-1]
                trailing = ','
            line = line[:m.start()] + f'_IF({cond}, {t}, {f})' + trailing
        out.append(line)
    return '\n'.join(out)

if __name__ == '__main__':
    with open('Visuals/World/Builder.luau', 'r', encoding='utf-8') as f:
        src = f.read()
    cleaned = clean_luau(src)
    for i, l in enumerate(cleaned.splitlines()[:20]):
        print(f'{i}: {l}')
