cmake_minimum_required(VERSION 3.10)
project(hello-world VERSION 1.0.0)

# Install the Flask application
install(PROGRAMS src/app.py
        DESTINATION bin
        RENAME hello-world-server)

# Install static web assets
install(DIRECTORY share/www
        DESTINATION share)

# Install default configuration
install(FILES etc/config.json.default
        DESTINATION etc)

# Generate manifest.json from template
configure_file(manifest.template.json
               ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
               @ONLY)
install(FILES ${CMAKE_CURRENT_BINARY_DIR}/manifest.json
        DESTINATION .)
