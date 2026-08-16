"""
Purpose: Package root for curtain-bridge, the KVM automation daemon that runs
         on Raspberry Pi (TinyPilot) hardware, independent of the protected
         Mac's own power/network path.
Inputs: none (package marker).
Outputs: re-exports the public client/error surface for convenient imports,
         e.g. ``from curtain_bridge import TinyPilotClient``.
Constraints: this package must never import anything from the Swift/Curtain.app
             codebase -- Bridge and Curtain.app communicate only over the
             network (SSH deploy + HTTP), never via a shared module boundary.
SPORT: MASTER-APPS (Bridge/ deployment artifact)
"""

from curtain_bridge.tinypilot_client import (
    TinyPilotAPIError,
    TinyPilotClient,
    TinyPilotLicenseError,
)

__all__ = [
    "TinyPilotClient",
    "TinyPilotAPIError",
    "TinyPilotLicenseError",
]

__version__ = "0.1.0"
