"""
Treasure Hunt Stages API

This module provides API endpoints for the multi-stage treasure hunt:
- Stage 1: Player finds original X, discovers IOU note
- Stage 2: Player meets Corgi, learns bandits stole remaining treasure
- Stage 3: Player catches bandits, recovers remaining treasure

These endpoints manage stage transitions and coordinate NPC interactions.
"""

import time
import logging
from datetime import datetime
from typing import Dict, Optional
from flask import Blueprint, request, jsonify

# Import NPC classes
from npcs import CaptainBonesNPC, CorgiNPC

# Set up logging
logger = logging.getLogger('treasure_hunt_stages')

# Create Blueprint for stage-related endpoints
stages_bp = Blueprint('treasure_hunt_stages', __name__)

# NPC instances
captain_bones = CaptainBonesNPC()
corgi_npc = CorgiNPC()


def get_db_connection():
    """Import and use the database connection from app.py."""
    # This will be set when the blueprint is registered
    from app import get_db_connection as app_get_db
    return app_get_db()


# ============================================================================
# Stage 1: IOU Discovery
# ============================================================================

@stages_bp.route('/api/treasure-hunts/<device_uuid>/discover-iou', methods=['POST'])
def discover_iou(device_uuid: str):
    """Player has arrived at the treasure X and discovered the IOU note.
    
    This triggers Stage 2:
    - Returns the IOU note content
    - Spawns Corgi NPC nearby (within 20m)
    - Generates bandit hideout location
    - Updates hunt stage to 'stage_2'
    
    Request body:
    {
        "current_latitude": 37.7749,
        "current_longitude": -122.4194
    }
    
    Returns:
    {
        "stage": "stage_2",
        "iou_note": "...",
        "corgi_location": {...},
        "bandit_location": {...},
        "new_map_marker": {...}
    }
    """
    request_id = f"iou_{int(time.time() * 1000)}"
    logger.info(f"[{request_id}] IOU discovery request from device {device_uuid[:8]}...")
    
    data = request.json or {}
    
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get active treasure hunt for this device
        cursor.execute('''
            SELECT id, treasure_latitude, treasure_longitude, current_stage
            FROM treasure_hunts 
            WHERE device_uuid = ? AND status = 'active'
            ORDER BY created_at DESC
            LIMIT 1
        ''', (device_uuid,))
        
        hunt = cursor.fetchone()
        
        if not hunt:
            return jsonify({
                'error': 'No active treasure hunt found',
                'message': 'Start a new treasure hunt first'
            }), 404
        
        hunt_id = hunt['id']
        treasure_lat = hunt['treasure_latitude']
        treasure_lon = hunt['treasure_longitude']
        current_stage = hunt['current_stage'] or 'stage_1'
        
        # Check if already in stage 2 or beyond
        if current_stage != 'stage_1':
            # Already discovered IOU, return existing data
            cursor.execute('''
                SELECT corgi_latitude, corgi_longitude, bandit_latitude, bandit_longitude
                FROM treasure_hunts WHERE id = ?
            ''', (hunt_id,))
            existing = cursor.fetchone()
            
            if existing and existing['corgi_latitude']:
                return jsonify({
                    'stage': current_stage,
                    'message': 'IOU already discovered',
                    'iou_note': corgi_npc.get_iou_note(),
                    'corgi_location': {
                        'latitude': existing['corgi_latitude'],
                        'longitude': existing['corgi_longitude'],
                        'npc_id': corgi_npc.NPC_ID,
                        'npc_name': corgi_npc.NPC_NAME
                    },
                    'bandit_location': {
                        'latitude': existing['bandit_latitude'],
                        'longitude': existing['bandit_longitude'],
                        'name': 'Bandit Hideout'
                    }
                }), 200
        
        # Generate Stage 2 data using Corgi NPC
        stage_2_data = corgi_npc.handle_iou_discovery(
            device_uuid=device_uuid,
            treasure_location={
                'latitude': treasure_lat,
                'longitude': treasure_lon
            }
        )
        
        if 'error' in stage_2_data:
            return jsonify(stage_2_data), 400
        
        # Update database with Stage 2 data
        corgi_loc = stage_2_data['corgi_location']
        bandit_loc = stage_2_data['bandit_location']
        
        cursor.execute('''
            UPDATE treasure_hunts 
            SET current_stage = 'stage_2',
                corgi_latitude = ?,
                corgi_longitude = ?,
                bandit_latitude = ?,
                bandit_longitude = ?,
                iou_discovered_at = ?
            WHERE id = ?
        ''', (
            corgi_loc['latitude'],
            corgi_loc['longitude'],
            bandit_loc['latitude'],
            bandit_loc['longitude'],
            datetime.utcnow().isoformat(),
            hunt_id
        ))
        
        conn.commit()
        conn.close()
        
        logger.info(f"[{request_id}] Stage 2 activated - Corgi at ({corgi_loc['latitude']}, {corgi_loc['longitude']})")
        
        return jsonify({
            'success': True,
            'hunt_id': hunt_id,
            **stage_2_data
        }), 200
        
    except Exception as e:
        logger.error(f"[{request_id}] Error discovering IOU: {e}")
        return jsonify({'error': str(e)}), 500


# ============================================================================
# Stage 2: Corgi Interaction
# ============================================================================

@stages_bp.route('/api/npcs/corgi/interact', methods=['POST'])
def interact_with_corgi():
    """Interact with Barnaby the Corgi.
    
    First interaction triggers the confession story.
    Subsequent interactions provide hints about bandits.
    
    Request body:
    {
        "device_uuid": "abc123",
        "message": "What happened to the treasure?",
        "user_location": {"latitude": 37.7749, "longitude": -122.4194}
    }
    
    Returns:
    {
        "response": "...",
        "story_event": "confession",
        "should_update_map": true,
        "bandit_hint": "..."
    }
    """
    request_id = f"corgi_chat_{int(time.time() * 1000)}"
    
    data = request.json
    if not data:
        return jsonify({'error': 'Request body required'}), 400
    
    device_uuid = data.get('device_uuid')
    message = data.get('message', '')
    user_location = data.get('user_location')
    
    if not device_uuid:
        return jsonify({'error': 'device_uuid required'}), 400
    
    logger.info(f"[{request_id}] Corgi interaction from device {device_uuid[:8]}...")
    
    try:
        # Get current treasure hunt stage
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT id, current_stage, bandit_latitude, bandit_longitude
            FROM treasure_hunts 
            WHERE device_uuid = ? AND status = 'active'
            ORDER BY created_at DESC
            LIMIT 1
        ''', (device_uuid,))
        
        hunt = cursor.fetchone()
        current_stage = hunt['current_stage'] if hunt else 'stage_1'
        
        # Generate Corgi response
        result = corgi_npc.interact(
            user_message=message,
            device_uuid=device_uuid,
            user_location=user_location,
            treasure_hunt_stage=current_stage
        )
        
        # If this is the confession, update the database
        if result.get('story_event') == 'confession' and hunt:
            cursor.execute('''
                UPDATE treasure_hunts 
                SET corgi_met_at = ?
                WHERE id = ?
            ''', (datetime.utcnow().isoformat(), hunt['id']))
            conn.commit()
            
            # Include bandit location in response
            if hunt['bandit_latitude'] and hunt['bandit_longitude']:
                result['bandit_location'] = {
                    'latitude': hunt['bandit_latitude'],
                    'longitude': hunt['bandit_longitude'],
                    'name': 'Bandit Hideout'
                }
        
        conn.close()
        
        return jsonify(result), 200
        
    except Exception as e:
        logger.error(f"[{request_id}] Error in Corgi interaction: {e}")
        return jsonify({'error': str(e)}), 500


@stages_bp.route('/api/treasure-hunts/<device_uuid>/get-corgi-story', methods=['GET'])
def get_corgi_story(device_uuid: str):
    """Get the full Corgi confession story (for displaying in UI).
    
    Returns the IOU note content and confession story text.
    """
    return jsonify({
        'npc_name': corgi_npc.NPC_NAME,
        'npc_type': corgi_npc.NPC_TYPE,
        'iou_note': corgi_npc.get_iou_note(),
        'confession_story': corgi_npc.get_confession_story(short=False),
        'confession_short': corgi_npc.get_confession_story(short=True)
    }), 200


# ============================================================================
# Stage 3: Bandit Capture
# ============================================================================

@stages_bp.route('/api/treasure-hunts/<device_uuid>/catch-bandits', methods=['POST'])
def catch_bandits(device_uuid: str):
    """Player has arrived at the bandit hideout and captured them.
    
    This completes the treasure hunt:
    - Returns victory message
    - Awards remaining treasure (half)
    - Updates hunt status to 'completed'
    - Records bandits_caught_at timestamp
    
    Request body:
    {
        "current_latitude": 37.7749,
        "current_longitude": -122.4194
    }
    
    Returns:
    {
        "stage": "completed",
        "victory_message": "...",
        "rewards": {...},
        "game_complete": true
    }
    """
    request_id = f"bandits_{int(time.time() * 1000)}"
    logger.info(f"[{request_id}] Bandit capture request from device {device_uuid[:8]}...")
    
    data = request.json or {}
    current_lat = data.get('current_latitude')
    current_lon = data.get('current_longitude')
    
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        # Get active treasure hunt
        cursor.execute('''
            SELECT id, current_stage, bandit_latitude, bandit_longitude
            FROM treasure_hunts 
            WHERE device_uuid = ? AND status = 'active'
            ORDER BY created_at DESC
            LIMIT 1
        ''', (device_uuid,))
        
        hunt = cursor.fetchone()
        
        if not hunt:
            return jsonify({
                'error': 'No active treasure hunt found'
            }), 404
        
        hunt_id = hunt['id']
        current_stage = hunt['current_stage'] or 'stage_1'
        
        # Validate player is in Stage 2 or later
        if current_stage == 'stage_1':
            return jsonify({
                'error': 'Must discover IOU and meet Corgi first',
                'current_stage': current_stage
            }), 400
        
        # Optional: Validate player is near bandit location
        # (Could be enforced or just trusted)
        
        # Get victory data from Corgi NPC
        victory_data = corgi_npc.handle_bandit_capture(device_uuid)
        
        # Update database
        cursor.execute('''
            UPDATE treasure_hunts 
            SET current_stage = 'completed',
                status = 'completed',
                bandits_caught_at = ?,
                completed_at = ?,
                treasure_amount_recovered = 'half'
            WHERE id = ?
        ''', (
            datetime.utcnow().isoformat(),
            datetime.utcnow().isoformat(),
            hunt_id
        ))
        
        conn.commit()
        conn.close()
        
        logger.info(f"[{request_id}] Treasure hunt #{hunt_id} completed!")
        
        return jsonify({
            'success': True,
            'hunt_id': hunt_id,
            **victory_data
        }), 200
        
    except Exception as e:
        logger.error(f"[{request_id}] Error catching bandits: {e}")
        return jsonify({'error': str(e)}), 500


# ============================================================================
# Stage Status & Map Updates
# ============================================================================

@stages_bp.route('/api/treasure-hunts/<device_uuid>/stage', methods=['GET'])
def get_hunt_stage(device_uuid: str):
    """Get current stage and all relevant locations for the treasure hunt.
    
    Returns:
    {
        "current_stage": "stage_2",
        "treasure_location": {...},
        "corgi_location": {...},
        "bandit_location": {...},
        "map_update": {...}
    }
    """
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        
        cursor.execute('''
            SELECT id, treasure_latitude, treasure_longitude,
                   current_stage, corgi_latitude, corgi_longitude,
                   bandit_latitude, bandit_longitude,
                   iou_discovered_at, corgi_met_at, bandits_caught_at,
                   status, created_at, completed_at
            FROM treasure_hunts 
            WHERE device_uuid = ? AND status IN ('active', 'completed')
            ORDER BY created_at DESC
            LIMIT 1
        ''', (device_uuid,))
        
        hunt = cursor.fetchone()
        conn.close()
        
        if not hunt:
            return jsonify({
                'has_active_hunt': False,
                'message': 'No treasure hunt found'
            }), 404
        
        current_stage = hunt['current_stage'] or 'stage_1'
        
        result = {
            'hunt_id': hunt['id'],
            'current_stage': current_stage,
            'status': hunt['status'],
            'created_at': hunt['created_at'],
            
            'treasure_location': {
                'latitude': hunt['treasure_latitude'],
                'longitude': hunt['treasure_longitude']
            },
            
            'stage_progress': {
                'iou_discovered': hunt['iou_discovered_at'] is not None,
                'iou_discovered_at': hunt['iou_discovered_at'],
                'corgi_met': hunt['corgi_met_at'] is not None,
                'corgi_met_at': hunt['corgi_met_at'],
                'bandits_caught': hunt['bandits_caught_at'] is not None,
                'bandits_caught_at': hunt['bandits_caught_at']
            }
        }
        
        # Include Corgi location if in Stage 2+
        if current_stage in ['stage_2', 'completed'] and hunt['corgi_latitude']:
            result['corgi_location'] = {
                'latitude': hunt['corgi_latitude'],
                'longitude': hunt['corgi_longitude'],
                'npc_id': corgi_npc.NPC_ID,
                'npc_name': corgi_npc.NPC_NAME
            }
        
        # Include bandit location if in Stage 2+
        if current_stage in ['stage_2', 'completed'] and hunt['bandit_latitude']:
            result['bandit_location'] = {
                'latitude': hunt['bandit_latitude'],
                'longitude': hunt['bandit_longitude'],
                'name': 'Bandit Hideout'
            }
            
            # Include map update data
            result['map_update'] = corgi_npc.get_stage_2_map_update(
                original_treasure_location={
                    'latitude': hunt['treasure_latitude'],
                    'longitude': hunt['treasure_longitude']
                },
                bandit_location={
                    'latitude': hunt['bandit_latitude'],
                    'longitude': hunt['bandit_longitude']
                }
            )
        
        if current_stage == 'completed':
            result['completed_at'] = hunt['completed_at']
            result['completion_message'] = "🎉 Treasure hunt complete! You recovered the treasure!"
        
        return jsonify(result), 200
        
    except Exception as e:
        logger.error(f"Error getting hunt stage: {e}")
        return jsonify({'error': str(e)}), 500


# ============================================================================
# Captain Bones Endpoints
# ============================================================================

@stages_bp.route('/api/npcs/captain-bones/interact', methods=['POST'])
def interact_with_captain_bones():
    """Interact with Captain Bones (the skeleton pirate).
    
    Request body:
    {
        "device_uuid": "abc123",
        "message": "Tell me about the treasure!",
        "user_location": {"latitude": 37.7749, "longitude": -122.4194},
        "include_map_piece": false
    }
    """
    request_id = f"bones_chat_{int(time.time() * 1000)}"
    
    data = request.json
    if not data:
        return jsonify({'error': 'Request body required'}), 400
    
    device_uuid = data.get('device_uuid')
    message = data.get('message', '')
    user_location = data.get('user_location')
    include_map_piece = data.get('include_map_piece', False)
    
    if not device_uuid:
        return jsonify({'error': 'device_uuid required'}), 400
    
    logger.info(f"[{request_id}] Captain Bones interaction from device {device_uuid[:8]}...")
    
    try:
        result = captain_bones.interact(
            user_message=message,
            device_uuid=device_uuid,
            user_location=user_location,
            include_map_piece=include_map_piece
        )
        
        return jsonify(result), 200
        
    except Exception as e:
        logger.error(f"[{request_id}] Error in Captain Bones interaction: {e}")
        return jsonify({'error': str(e)}), 500


@stages_bp.route('/api/npcs/captain-bones/info', methods=['GET'])
def get_captain_bones_info():
    """Get Captain Bones character information."""
    return jsonify(captain_bones.get_character_info()), 200


@stages_bp.route('/api/npcs/corgi/info', methods=['GET'])
def get_corgi_info():
    """Get Corgi character information."""
    return jsonify(corgi_npc.get_character_info()), 200


def register_stages_blueprint(app):
    """Register the stages blueprint with the Flask app.
    
    Call this from app.py to add all stage-related endpoints.
    
    Usage in app.py:
        from treasure_hunt_stages import register_stages_blueprint
        register_stages_blueprint(app)
    """
    app.register_blueprint(stages_bp)
    print("✅ Treasure hunt stages endpoints registered")












