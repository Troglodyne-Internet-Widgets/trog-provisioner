# Installed by Provisioner::Recipe::nvm, through bashrc_d.
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
nvm use node &>/dev/null
[ -n "$NVM_BIN" ] && export NODE_PATH="${NVM_BIN%/bin}/lib/node_modules"
true
