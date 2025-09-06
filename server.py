from flask import Flask, request, jsonify
import os
from uuid import uuid4
from flask_cors import CORS
from fingerprint_processing import register_fingerprint, verify_fingerprint, is_fingerprint_present
from database import get_fingerprint_by_id, save_fingerprint, delete_fingerprint, update_fingerprint, get_db_connection

app = Flask(__name__)
CORS(app)

UPLOAD_FOLDER = "uploads"
os.makedirs(UPLOAD_FOLDER, exist_ok=True)

# ✅ Homepage route
@app.route("/", methods=["GET"])
def home():
    return "<h2>✅ Fingerprint Recognition Server is Running</h2>", 200

# Register route
@app.route("/register", methods=["POST"])
def register():
    file = request.files.get("file")
    user_id = request.form.get("user_id")
    username = request.form.get("username")
    phone = request.form.get("phone")

    if not all([file, user_id, username, phone]):
        return jsonify({"message": "Missing required fields"}), 400

    filepath = os.path.join(UPLOAD_FOLDER, f"{uuid4().hex}_{file.filename}")
    file.save(filepath)

    result = register_fingerprint(filepath, user_id, username, phone)
    return jsonify({"message": result}), (200 if "success" in result.lower() else 400)

@app.route("/verify", methods=["POST"])
def verify():
    file = request.files.get("file")
    user_id = request.form.get("user_id")

    if not file or not user_id:
        return jsonify({"message": "Missing input"}), 400

    filepath = os.path.join(UPLOAD_FOLDER, f"{uuid4().hex}_{file.filename}")
    file.save(filepath)

    result = verify_fingerprint(filepath, user_id)

    # Handle blurry image
    if result.get("status") == "blurry":
        print("[DEBUG] Verification failed: Image is blurry.")
        return jsonify({
            "match": False,
            "status": "blurry",
            "message": "Image is blurry."
        }), 400

    # Handle no fingerprint present
    if result.get("status") == "no_fingerprint":
        print("[DEBUG] Verification failed: No fingerprint pattern detected.")
        return jsonify({
            "match": False,
            "status": "no_fingerprint",
            "message": "No fingerprint pattern detected."
        }), 422

    # Handle no match
    if not result.get("match", False):
        print("[DEBUG] Verification failed: No match found.")
        return jsonify({
            "match": False,
            "status": "no_match",
            "message": "No match found"
        }), 404

    # If match found
    response = {
        "match": True,
        "status": "match_found",
        "username": result.get("username"),
        "accuracy": float(result.get("accuracy", 0)),
        "orb_score": float(result.get("orb_score", 0)),
        "minutiae_score": float(result.get("minutiae_score", 0)),
        "message": "Match found"
    }
    return jsonify(response), 200

# Fetch current users route
@app.route("/users", methods=["GET"])
def get_users():
    users = []
    try:
        # Fetching all users from the database
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT user_id, username FROM fingerprints")  # Only fetching user_id and username
        users = cursor.fetchall()
        conn.close()

        users_list = []
        for user in users:
            users_list.append({
                "user_id": user[0],
                "username": user[1]
            })

        return jsonify(users_list), 200
    except Exception as e:
        return jsonify({"message": f"Error fetching users: {str(e)}"}), 500
    
# Fetch single user details by user_id
@app.route("/user/<user_id>", methods=["GET"])
def get_user(user_id):
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("SELECT user_id, username, phone FROM fingerprints WHERE user_id = ?", (user_id,))
        user = cursor.fetchone()
        conn.close()

        if user:
            return jsonify({
                "user_id": user[0],
                "username": user[1],
                "phone": user[2]
            }), 200
        else:
            return jsonify({"message": "User not found."}), 404
    except Exception as e:
        return jsonify({"message": f"Error fetching user: {str(e)}"}), 500

# Delete user route
@app.route("/delete/<user_id>", methods=["DELETE"])
def delete_user(user_id):
    try:
        result = delete_fingerprint(user_id)
        return jsonify({"message": result}), 200
    except Exception as e:
        return jsonify({"message": f"Error deleting user: {str(e)}"}), 500

# Update user route
@app.route("/update/<user_id>", methods=["PUT"])
def update_user(user_id):
    data = request.json
    username = data.get("username")
    phone = data.get("phone")

    if not username or not phone:
        return jsonify({"message": "Username and phone are required."}), 400

    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        cursor.execute("UPDATE fingerprints SET username = ?, phone = ? WHERE user_id = ?", (username, phone, user_id))
        conn.commit()
        conn.close()

        return jsonify({"message": f"User {user_id} updated successfully."}), 200
    except Exception as e:
        return jsonify({"message": f"Error updating user: {str(e)}"}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=True)
