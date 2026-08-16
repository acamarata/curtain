"""
Purpose: Package marker for curtain_bridge.fixtures, the checked-in
         reference-asset tree consumed by curtain_bridge.detection at
         runtime (not just by tests) via importlib.resources.
Inputs: none (package marker).
Outputs: none.
Constraints: this subpackage ships inside the built distribution (see
             pyproject.toml's [tool.hatch.build.targets.wheel] packages
             entry) -- it is a runtime dependency of detection.py, not a
             test-only fixture directory.
SPORT: MASTER-APPS (Bridge/ deployment artifact, T-P1-E12-01)
"""
