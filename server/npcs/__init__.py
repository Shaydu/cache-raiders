"""
NPC (Non-Player Character) modules for CacheRaiders.

This package contains character classes for all NPCs in the game:
- Captain Bones: The skeleton pirate who gives treasure maps
- Corgi Traveller: The friendly dog who reveals the treasure was moved
- Bandits: The thieves who stole the remaining treasure (Stage 3)
"""

from .captain_bones_npc import CaptainBonesNPC
from .corgi_npc import CorgiNPC

__all__ = ['CaptainBonesNPC', 'CorgiNPC']



