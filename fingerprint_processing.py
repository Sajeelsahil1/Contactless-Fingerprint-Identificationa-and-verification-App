import cv2
import numpy as np
import skimage.morphology as morph
from skimage.filters import threshold_otsu
from database import save_fingerprint, get_fingerprint_by_id
from scipy.spatial import cKDTree
import concurrent.futures
import matplotlib
import matplotlib.pyplot as plt
matplotlib.use('Agg')
import argparse
import os
import uuid
import math
import threading
import warnings
warnings.filterwarnings("ignore", category=UserWarning, module="matplotlib")

orb = cv2.ORB_create(nfeatures=600)
bf = cv2.BFMatcher(cv2.NORM_HAMMING, crossCheck=True)

MATCH_THRESHOLD = 26

# Flags to toggle Gabor and ROI
USE_GABOR = True
USE_ROI = False
USE_MINUTIAE_FILTERING = True

def apply_gabor_filters(img, ksize=31):
    accum = np.zeros_like(img, dtype=np.float32)
    for theta in np.arange(0, np.pi, np.pi / 8):  # 8 orientations
        kernel = cv2.getGaborKernel((ksize, ksize), 4.0, theta, 10.0, 0.5, 0, ktype=cv2.CV_32F)
        fimg = cv2.filter2D(img, cv2.CV_32F, kernel)
        np.maximum(accum, fimg, out=accum)
    accum = cv2.normalize(accum, None, 0, 255, cv2.NORM_MINMAX)
    return np.uint8(accum)

def automatic_roi(image):
    print("[DEBUG] Applying ROI cropping...")
    blurred = cv2.GaussianBlur(image, (5, 5), 0)
    _, thresh = cv2.threshold(blurred, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    if not contours:
        return image
    largest_contour = max(contours, key=cv2.contourArea)
    x, y, w, h = cv2.boundingRect(largest_contour)
    return image[y:y + h, x:x + w]

def enhance_fingerprint(image):
    print("[DEBUG] Enhancing fingerprint using advanced pipeline...")

    # Resize to standard size
    image = cv2.resize(image, (512, 512))

    # CLAHE
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    clahe_img = clahe.apply(image)

    # Histogram Equalization
    hist_eq = cv2.equalizeHist(clahe_img)

    # Gaussian Blur
    blurred = cv2.GaussianBlur(hist_eq, (5, 5), 0)

    # Gabor Filter (if enabled)
    enhanced = apply_gabor_filters(blurred) if USE_GABOR else blurred

    # ROI Cropping (if enabled)
    if USE_ROI:
        enhanced = automatic_roi(enhanced)

    return enhanced

def skeletonize(image):
    thresh = threshold_otsu(image)
    binary = image > thresh
    skeleton = morph.skeletonize(binary).astype(np.uint8) * 255
    return skeleton

def extract_minutiae(image):
    skeleton_img = skeletonize(image)
    minutiae_endings = []
    minutiae_bifurcations = []

    rows, cols = skeleton_img.shape

    for i in range(1, rows - 1):
        for j in range(1, cols - 1):
            if skeleton_img[i, j] == 255:
                window = skeleton_img[i - 1:i + 2, j - 1:j + 2]
                count = np.sum(window == 255) - 1  # exclude center pixel

                if count == 1:
                    minutiae_type = "ending"
                elif count >= 3:
                    minutiae_type = "bifurcation"
                else:
                    continue

                if USE_MINUTIAE_FILTERING:
                    local_window = skeleton_img[max(i - 5, 0):i + 6, max(j - 5, 0):j + 6]
                    density = np.sum(local_window == 255)
                    if density < 10:
                        continue  # skip low-density noise

                if minutiae_type == "ending":
                    minutiae_endings.append((i, j))
                else:
                    minutiae_bifurcations.append((i, j))

    return np.array(minutiae_endings + minutiae_bifurcations)

# Visualization
def show_fingerprint_debug(original, enhanced, skeleton, minutiae, title="Fingerprint Debug View"):
    try:
        annotated = cv2.cvtColor(skeleton.copy(), cv2.COLOR_GRAY2BGR)
        for x, y in minutiae:
            cv2.circle(annotated, (y, x), 3, (0, 255, 0), 1)

        plt.figure(figsize=(20, 5))
        for idx, (img, lbl) in enumerate([
            (original, "Original"),
            (enhanced, "Enhanced"),
            (skeleton, "Skeletonized"),
            (annotated, "Minutiae Points")
        ]):
            plt.subplot(1, 4, idx + 1)
            plt.imshow(img, cmap='gray' if len(img.shape) == 2 else None)
            plt.title(lbl)
            plt.axis("off")

        plt.suptitle(title, fontsize=14)
        plt.tight_layout()
        os.makedirs("debug_output", exist_ok=True)
        safe_title = "".join(c for c in title if c.isalnum() or c in (' ', '_')).rstrip()
        filename = f"debug_output/{safe_title}.png"
        plt.savefig(filename)
        plt.close()
        print(f"[DEBUG] Plot saved to {filename}")
    except Exception as e:
        print(f"[WARN] Plotting skipped: {e}")

def is_fingerprint_present(image_path):
    image = cv2.imread(image_path)
    if image is None:
        print("[ERROR] Image is None. Cannot process fingerprint.")
        return False

    # Convert to grayscale
    gray = cv2.cvtColor(image, cv2.COLOR_BGR2GRAY)

    # Contrast Limited Adaptive Histogram Equalization (CLAHE)
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    enhanced = clahe.apply(gray)

    # Gabor filter to enhance fingerprint ridges
    gabor_kernel = cv2.getGaborKernel((21, 21), 4.0, np.pi/2, 10.0, 0.5, 0, ktype=cv2.CV_32F)
    filtered = cv2.filter2D(enhanced, cv2.CV_8UC3, gabor_kernel)

    # Threshold and find contours
    _, thresh = cv2.threshold(filtered, 50, 255, cv2.THRESH_BINARY)
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    # Check if any large contour (ridge pattern) exists
    large_contours = [c for c in contours if cv2.contourArea(c) > 1000]
    print(f"[DEBUG] Found {len(large_contours)} large contours (ridge patterns)")

    return len(large_contours) > 0

def is_image_blurry(image, threshold=5.0):
    lap_var = cv2.Laplacian(image, cv2.CV_64F).var()
    return lap_var < threshold

def register_fingerprint(image_path, user_id, username, phone, show_visual=True):
    print(f"\n[DEBUG] Starting registration for user ID: {user_id}")
    image = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)
    if image is None:
        return "Image could not be read."
    if is_image_blurry(image):
        print("[DEBUG] Registration failed: Image is blurry.")
        return "Image too blurry. Please capture a clearer fingerprint."
    if not is_fingerprint_present(image_path):
        print("[DEBUG] Registration failed: No fingerprint detected.")
        return "No fingerprint detected! Please place your finger properly."

    # Enhance fingerprint using the advanced pipeline
    enhanced_image = enhance_fingerprint(image)
    skeleton_img = skeletonize(enhanced_image)
    minutiae_points = extract_minutiae(enhanced_image)

    if show_visual:
        # Use the original loaded image for visualization clarity
        show_fingerprint_debug(original=image,
                               enhanced=enhanced_image,
                               skeleton=skeleton_img,
                               minutiae=minutiae_points,
                               title=f"Registration Debug: User {user_id}")

    print("[DEBUG] Extracting features...")
    with concurrent.futures.ThreadPoolExecutor() as executor:
        orb_future = executor.submit(lambda: orb.detectAndCompute(enhanced_image, None))
        minutiae_future = executor.submit(extract_minutiae, enhanced_image)
        keypoints, descriptors = orb_future.result()
        minutiae_points = minutiae_future.result()

    print(f"[DEBUG] ORB keypoints: {len(keypoints)}")
    print(f"[DEBUG] Minutiae points: {len(minutiae_points)}")

    if descriptors is None or len(descriptors) == 0:
        print("[DEBUG] Registration failed: No ORB descriptors found.")
        return "Fingerprint not detected."

    if get_fingerprint_by_id(user_id):
        return "User ID already registered."

    data = {
        "orb": descriptors.tolist(),
        "minutiae": minutiae_points.tolist(),
        "username": username,
        "phone": phone
    }

    result = save_fingerprint(user_id, data)
    print("[DEBUG] Registration successful.")
    return result or "Fingerprint registered successfully."

def rotate_image(image, angle):
    (h, w) = image.shape[:2]
    center = (w // 2, h // 2)
    M = cv2.getRotationMatrix2D(center, angle, 1.0)
    return cv2.warpAffine(image, M, (w, h), flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)

def verify_fingerprint(image_path, user_id,):
    print(f"\n[DEBUG] Starting verification for user ID: {user_id}")
    base_image = cv2.imread(image_path, cv2.IMREAD_GRAYSCALE)
    if base_image is None:
        return {
            "status": "error",
            "match": False,
            "accuracy": 0,
            "orb_score": 0,
            "minutiae_score": 0,
            "username": None,
            "message": "Invalid image file."
        }

    if is_image_blurry(base_image):
        print("[DEBUG] Verification failed: Image is blurry.")
        return {
            "status": "blurry",
            "match": False,
            "accuracy": 0,
            "orb_score": 0,
            "minutiae_score": 0,
            "username": None,
            "message": "Fingerprint image is too blurry."
        }

    if not is_fingerprint_present(image_path):
        print("[DEBUG] Verification failed: No fingerprint pattern detected.")
        return {
            "status": "no_fingerprint",
            "match": False,
            "accuracy": 0,
            "orb_score": 0,
            "minutiae_score": 0,
            "username": None,
            "message": "No fingerprint detected. Please try again."
        }

    stored = get_fingerprint_by_id(user_id)
    if not stored:
        print("[DEBUG] Verification failed: No data found for user.")
        return {
            "status": "no_user",
            "match": False,
            "accuracy": 0,
            "orb_score": 0,
            "minutiae_score": 0,
            "username": None,
            "message": "No fingerprint data found for this user ID."
        }

    stored_desc = np.array(stored["orb"], dtype=np.uint8)
    stored_minutiae = np.array(stored["minutiae"])
    username = stored.get("username", "")

    best_final_score = 0
    best_orb_score = 0
    best_minutiae_score = 0
    angles = [-10, -5, 0, 5, 10]
    print("[DEBUG] Starting multi-angle matching...")

    for angle in angles:
        print(f"[DEBUG] Trying rotation: {angle} degrees")
        rotated = rotate_image(base_image, angle)
        enhanced_image = enhance_fingerprint(rotated)
        skeleton_img = skeletonize(enhanced_image)
        minutiae_points = extract_minutiae(enhanced_image)

        with concurrent.futures.ThreadPoolExecutor() as executor:
            orb_future = executor.submit(lambda: orb.detectAndCompute(enhanced_image, None))
            minutiae_future = executor.submit(extract_minutiae, enhanced_image)
            keypoints, descriptors = orb_future.result()
            minutiae_points = minutiae_future.result()

        if descriptors is None or len(descriptors) == 0:
            continue

        matches = bf.match(descriptors, stored_desc)
        accuracy_orb = (len(matches) / max(len(descriptors), len(stored_desc))) * 100

        if len(minutiae_points) > 0 and len(stored_minutiae) > 0:
            tree = cKDTree(stored_minutiae)
            distances, _ = tree.query(minutiae_points, k=1, distance_upper_bound=6)
            matched_minutiae = np.sum(distances != np.inf)
            accuracy_minutiae = (matched_minutiae / max(len(minutiae_points), len(stored_minutiae))) * 100
        else:
            accuracy_minutiae = 0

        final_score = (accuracy_orb * 0.1) + (accuracy_minutiae * 0.9)

        print(f"[DEBUG] Rotation {angle}° → ORB: {accuracy_orb:.2f}% | Minutiae: {accuracy_minutiae:.2f}% | Final: {final_score:.2f}%")

        if final_score > best_final_score:
            best_final_score = final_score
            best_orb_score = accuracy_orb
            best_minutiae_score = accuracy_minutiae

    print(f"[DEBUG] Best scores → Final: {best_final_score:.2f}% | ORB: {best_orb_score:.2f}% | Minutiae: {best_minutiae_score:.2f}%")

    is_match = (
        best_final_score >= MATCH_THRESHOLD or
        (best_orb_score > 45 and best_minutiae_score > 15)
    )

    print(f"[DEBUG] Match {'successful' if is_match else 'failed'}.")
    return {
        "status": "match_found" if is_match else "no_match",
        "match": is_match,
        "accuracy": best_final_score,
        "orb_score": best_orb_score,
        "minutiae_score": best_minutiae_score,
        "username": username,
        "message": "Match found" if is_match else "No match found"
    }
