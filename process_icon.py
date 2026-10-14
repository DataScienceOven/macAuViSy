import cv2
import numpy as np

# Load the image
img = cv2.imread('assets/icon.jpg')

# Convert to grayscale to find the white background
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)

# Threshold to find non-white pixels (assuming background is close to white)
# Anything below 240 is considered the logo
_, thresh = cv2.threshold(gray, 240, 255, cv2.THRESH_BINARY_INV)

# Find contours of the logo
contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

if contours:
    # Find the largest contour (the logo itself)
    largest_contour = max(contours, key=cv2.contourArea)
    x, y, w, h = cv2.boundingRect(largest_contour)
    
    # Crop the image to the logo
    cropped = img[y:y+h, x:x+w]
    
    # Convert cropped image to BGRA (add alpha channel)
    bgra = cv2.cvtColor(cropped, cv2.COLOR_BGR2BGRA)
    
    # Optional: if the cropped image still has some white corners because it's rounded,
    # we can make pixels close to white transparent in the cropped image
    gray_cropped = cv2.cvtColor(cropped, cv2.COLOR_BGR2GRAY)
    _, mask = cv2.threshold(gray_cropped, 240, 255, cv2.THRESH_BINARY)
    bgra[mask == 255] = [255, 255, 255, 0] # Make white pixels transparent
    
    # Save as transparent PNG
    cv2.imwrite('assets/MenuIcon.png', bgra)
    print("Successfully processed icon and saved to MenuIcon.png")
else:
    print("Could not find the logo contour")

