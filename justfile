default: build install

# Build home/ from nonrational/dotfiles + the overlay (DOTFILES=~/.dotfiles just build for a local checkout)
build:
    ./build.sh

# Symlink home/ into $HOME on the VM
install:
    ./install.sh
