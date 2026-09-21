"""Build-time gate.
1) The Swiss AI vLLM fork must still register the Apertus 1.5 architecture.
2) Every UNGUARDED `from vllm... import X` in Dynamo's vLLM backend/frontend must resolve
   against THIS vLLM (catches Dynamo<->fork API mismatches that only show up on the first request).
"""
import ast, importlib, os, sys

def unguarded_vllm_imports(root):
    """Yield (file, lineno, module, name) for vllm imports not inside try/except or TYPE_CHECKING."""
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if not fn.endswith(".py"):
                continue
            path = os.path.join(dirpath, fn)
            try:
                tree = ast.parse(open(path, encoding="utf-8").read())
            except SyntaxError:
                continue
            def walk(node, guarded):
                for child in ast.iter_child_nodes(node):
                    g = guarded
                    if isinstance(child, ast.Try):
                        g = True
                    if isinstance(child, ast.If) and "TYPE_CHECKING" in ast.dump(child.test):
                        g = True
                    if (isinstance(child, ast.ImportFrom) and not g and child.module
                            and (child.module == "vllm" or child.module.startswith("vllm."))):
                        for a in child.names:
                            yield path, child.lineno, child.module, a.name
                    yield from walk(child, g)
            yield from walk(tree, False)

def check(root, resolve):
    missing, unverifiable = [], []
    for path, line, mod, name in unguarded_vllm_imports(root):
        status = resolve(mod, name)
        rel = os.path.relpath(path, root)
        if status == "missing":
            missing.append(f"{rel}:{line}  from {mod} import {name}")
        elif status != "ok":
            unverifiable.append(f"{rel}:{line}  {mod}.{name}  ({status})")
    return missing, unverifiable

def dynamo_subdir(sub):
    """Locate dynamo/<sub> on disk. `dynamo` is a namespace package (no __file__), so use __path__."""
    import dynamo
    for p in dynamo.__path__:
        d = os.path.join(p, sub)
        if os.path.isdir(d):
            return d
    raise SystemExit(f"FAIL: dynamo/{sub} not found in {list(dynamo.__path__)}")

def real_resolve(mod, name):
    try:
        m = importlib.import_module(mod)
    except ModuleNotFoundError as e:
        return "missing" if (e.name or "").startswith("vllm") else f"dep:{e.name}"
    except Exception as e:  # needs GPU/driver or optional deps at import time
        return f"import-error:{type(e).__name__}"
    if name == "*" or hasattr(m, name):
        return "ok"
    try:
        importlib.import_module(f"{mod}.{name}")
        return "ok"
    except Exception:
        return "missing"

if __name__ == "__main__":
    import vllm, torch
    from vllm import ModelRegistry
    archs = [a for a in ModelRegistry.get_supported_archs() if "pertus" in a.lower()]
    print("vllm", vllm.__version__, "| torch", torch.__version__, "| apertus archs:", archs)
    assert any(a != "ApertusForCausalLM" for a in archs), "Apertus 1.5 arch missing -> fork vLLM was overwritten"
    import dynamo.vllm, dynamo.frontend  # noqa: F401
    all_missing = []
    for sub in ("vllm", "frontend"):
        missing, unverifiable = check(dynamo_subdir(sub), real_resolve)
        all_missing += missing
        print(f"dynamo/{sub}: {len(missing)} missing vLLM symbols, {len(unverifiable)} unverifiable at build time")
        for u in unverifiable[:5]:
            print("   (unverifiable)", u)
    if all_missing:
        print("\nDynamo expects vLLM symbols this fork does not have:")
        print("\n".join("   " + m for m in all_missing[:30]))
        sys.exit("FAIL: Dynamo version incompatible with the Swiss AI vLLM fork -> pin an older ai-dynamo")
    print("dynamo <-> fork vLLM API check OK")
