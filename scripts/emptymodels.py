import json
import os
from pathlib import Path

registry = json.loads(Path('broker-registry.json').read_text())
account = registry['accounts'][0]

missing_pricing = [m for m in account['models'] if not m.get('pricing')]
if missing_pricing:
    print(f"❌ {len(missing_pricing)} model(s) still have no pricing in registry:")
    for m in missing_pricing:
        print(f"  - {m['route']}: upstream={m['upstream']}")
else:
    print(f"✅ All models in registry have pricing")

# Also check deployed models
import subprocess
result = subprocess.run(
    ['curl', '-s', '-X', 'GET', 'https://localhost/model/info',
        '-H', f'Authorization: Bearer {os.environ.get("LITELLM_MASTER_KEY")}',
        '--insecure'],
    capture_output=True, text=True
)

if result.returncode == 0:
    try:
        data = json.loads(result.stdout)
        models = data.get('data', [])
        without_costs = [m for m in models if not m.get('model_info', {}).get('input_cost_per_token')]
        if without_costs:
            print(f"\n⚠️   {len(without_costs)} deployed model(s) missing costs:")
            for m in without_costs[:5]:
                print(f"  - {m.get('model_name')}")
    except:
        pass
