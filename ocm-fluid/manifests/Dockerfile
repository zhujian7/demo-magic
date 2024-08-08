FROM ubuntu:20.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    s3fs \
    fuse \
    awscli \
    && rm -rf /var/lib/apt/lists/*

# Create a directory for the S3 mount
RUN mkdir /mnt/s3

# Ensure FUSE is executable
RUN chmod +x /usr/bin/fusermount

# Optional: Add entrypoint script
ENTRYPOINT ["/bin/sh", "-c"]
