FROM quay.io/zhujian/kube-ai-vllm:0.4.1

# Install dependencies
RUN apt-get update
RUN apt-get install -y s3fs
RUN apt-get install -y fuse
# RUN apt-get install -y awscli
RUN rm -rf /var/lib/apt/lists/*

# Create a directory for the S3 mount
RUN mkdir /mnt/s3

# Ensure FUSE is executable
RUN chmod +x /usr/bin/fusermount

# Optional: Add entrypoint script
ENTRYPOINT ["/bin/sh", "-c"]
