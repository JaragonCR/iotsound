# Gemini Coding Assistant Instructions for balenaSound

This document provides instructions for the Gemini coding assistant to effectively contribute to the balenaSound project.

## Project Overview

balenaSound is a multi-room audio streaming solution built on balenaCloud. It uses a microservices architecture, with different services running in Docker containers. The core services are:

*   **audio**: Manages audio routing using PulseAudio.
*   **sound-supervisor**: The main control service, written in TypeScript. It manages the fleet, handles audio routing, and provides a web UI.
*   **multiroom-server/multiroom-client**: Handles multi-room audio synchronization using Snapcast.
*   **Plugins**: Additional services that provide features like Spotify, AirPlay, and Bluetooth.

## Development Conventions

### General

*   **Languages**: The project primarily uses **TypeScript** for the `sound-supervisor` and **shell scripts** for service startup and configuration.
*   **Architecture**: The project follows a microservices architecture. Changes to one service should be mindful of their impact on other services.
*   **Configuration**: The system is configured using environment variables. When adding new features, expose configuration options as environment variables.

### Commit Messages

The project has strict commit message guidelines. **All commits must follow these guidelines.**

*   **Structure**:
    ```
    <scope (optional)>: <subject (mandatory)>
    --BLANK LINE--
    (optional) <body>
    --BLANK LINE--
    (optional) Connects-to: #issue-number
    (mandatory) Change-type: major | minor | patch
    (optional) Signed-off-by: Foo Bar <foobar@balena.io>
    ```
*   **`scope`**: The service or area of the project the commit affects (e.g., `docs`, `airplay`, `multi-room`).
*   **`subject`**: A short, imperative, present-tense description of the change.
*   **`body`**: A detailed explanation of the changes.
*   **`Connects-to`**: Link to a related issue if applicable.
*   **`Change-type`**: `major`, `minor`, or `patch`. This is used for automatic versioning.
*   **`Signed-off-by`**: Optional, but good practice.

### TypeScript (`sound-supervisor`)

*   **Build**: Run `npm run build` in the `core/sound-supervisor` directory to compile the TypeScript code.
*   **Style**: Follow the existing code style and the rules in `tsconfig.json`. The project uses strict type checking.
*   **Dependencies**: Use `npm` to manage dependencies. Add new dependencies to `package.json`.

### Docker

*   **Dockerfiles**: The project uses `Dockerfile.template` files. These are templates that are processed by the balenaCloud build system.
*   **Services**: Services are defined in `docker-compose.yml`. When adding a new service, add it to this file.

### Shell Scripts

*   **Style**: Follow the existing shell script style. Use `set -e` to exit on error.
*   **Purpose**: Shell scripts are primarily used to start services and configure them based on environment variables.

## Making Changes

1.  **Understand the architecture**: Before making changes, understand how the different services interact. The `docs/ARCHITECTURE.md` file is a good starting point.
2.  **Follow the conventions**: Adhere to the coding style, commit message guidelines, and other conventions described in this document.
3.  **Test your changes**: While there are no visible tests in the project, it's important to test your changes manually. The `CONTRIBUTING.md` file mentions that the CI system runs tests, so ensure your changes are high quality.
4.  **Update documentation**: If you add a new feature or change existing behavior, update the documentation in the `docs` directory.
