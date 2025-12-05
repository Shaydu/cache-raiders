"""
Find Log Module - Support for multiple finds per object (find log functionality)
"""

from flask import Blueprint, jsonify, request
import sqlite3
from datetime import datetime
from .app import get_db_connection, socketio

find_log_bp = Blueprint('find极


