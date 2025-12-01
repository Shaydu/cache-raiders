FROM python:3.11-slim

WORKDIR /app

# Copy requirements and install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .
COPY admin.html .
COPY llm_service.py .
COPY map_feature_service.py .
COPY treasure_map_service.py .
COPY static ./static

# Create directory for database (will be persisted via volume)
RUN mkdir -p /app/data

# Expose port
EXPOSE 5001

# Set environment variables
ENV FLASK_APP=app.py
ENV FLASK_ENV=production

# Run the application
CMD ["python", "app.py"]







