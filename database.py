import sqlite3
import json
import csv
import numpy as np
import os
import threading

DB_FILE = "fingerprints.db"
CSV_BACKUP_FILE = "fingerprint_backup.csv"

def get_db_connection():
    return sqlite3.connect(DB_FILE, check_same_thread=False)

# Create table with user_id, username, phone, and descriptors
conn = get_db_connection()
cursor = conn.cursor()
cursor.execute("""
    CREATE TABLE IF NOT EXISTS fingerprints (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        user_id TEXT UNIQUE,
        username TEXT,
        phone TEXT,
        descriptors TEXT
    )
""")
cursor.execute("CREATE INDEX IF NOT EXISTS idx_user_id ON fingerprints(user_id);")
conn.commit()
conn.close()

def save_fingerprint(user_id, data):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()

        data["orb"] = np.array(data["orb"], dtype=np.uint8).tolist()
        descriptors_json = json.dumps(data)

        cursor.execute(
            "INSERT INTO fingerprints (user_id, username, phone, descriptors) VALUES (?, ?, ?, ?)",
            (user_id, data.get("username", ""), data.get("phone", ""), descriptors_json)
        )
        conn.commit()
        conn.close()

        threading.Thread(target=backup_to_csv, daemon=True).start()
        return "Fingerprint registered successfully."

    except sqlite3.IntegrityError:
        return "User ID already registered."
    except Exception as e:
        return f"Error saving fingerprint: {str(e)}"

def get_fingerprint_by_id(user_id):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT descriptors FROM fingerprints WHERE user_id = ?", (user_id,))
    row = cursor.fetchone()
    conn.close()

    if not row:
        return None

    try:
        data = json.loads(row[0])
        data["orb"] = np.array(data["orb"], dtype=np.uint8)
        return data
    except Exception as e:
        print(f"Error loading fingerprint for user_id {user_id}: {e}")
        return None

def delete_fingerprint(user_id):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("DELETE FROM fingerprints WHERE user_id = ?", (user_id,))
        conn.commit()
        conn.close()

        # backup_to_csv() removed here
        return f"User {user_id} deleted successfully."
    except Exception as e:
        return f"Error deleting fingerprint for user_id {user_id}: {str(e)}"

def update_fingerprint(user_id, username, phone):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("UPDATE fingerprints SET username = ?, phone = ? WHERE user_id = ?", (username, phone, user_id))
        conn.commit()
        conn.close()

        # backup_to_csv() removed here
        return f"User {user_id} updated successfully."
    except Exception as e:
        return f"Error updating fingerprint for user_id {user_id}: {str(e)}"

def backup_to_csv():
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT user_id, username, phone, descriptors FROM fingerprints")
        rows = cursor.fetchall()
        conn.close()

        with open(CSV_BACKUP_FILE, mode="w", newline="") as file:
            writer = csv.writer(file)
            writer.writerow(["UserID", "Username", "Phone", "Descriptors"])
            for row in rows:
                writer.writerow(row)
    except Exception as e:
        print(f"Error backing up CSV: {e}")


