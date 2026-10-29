# Include inside CircuitLab's HTTPS server block only.
# Public build assets only; authenticated API responses are never matched here.
location ~* ^/(?:app|assets)/.+\.(?:js|css|json|wasm|svg)$ {
    try_files $uri =404;
    gzip on;
    gzip_vary on;
    gzip_comp_level 5;
    gzip_min_length 1024;
    gzip_types application/javascript text/javascript text/css application/json application/wasm image/svg+xml;
}
