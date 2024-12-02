{
  description = ''
    Yo dawg I heard you like build abstractions so I put the hydra in the kubernetes so you can experience resource exhaustion while you experience resource exhaustion
  '';
  inputs = {
    #
    # this is EXTREMELY ANNOYING
    #
    # - we need hydra with the Ma27 diverted store patches
    # - we need nix with some diverted store patches that were added after the 2.24 branch-off
    # - hydra master still only works with nix 2.24
    # - the hydra/nix-next branch is actually older than nix 2.24
    # - so we need to use hydra stable + cherry picked patches with nix 2.24 + cherry picked patches
    # - but we don't really want nix's inputs to be locked, I think?
    #
    # awful.
    #
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nix.url = "github:rhelmot/nix/2_24-extra";
    nix.inputs.nixpkgs.follows = "nixpkgs";
    hydra.url = "github:rhelmot/hydra/62dfe33b90129c6124720d5a093859592aa8f94e";
    hydra.inputs.nix.follows = "nix";
    hydra.inputs.nixpkgs.follows = "nixpkgs";
    attic.url = "github:zhaofengli/attic";
    attic.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs = { self, nixpkgs, attic, hydra, nix, ... }: let
    system = "x86_64-linux";
    provisionerScript = pkgs.runCommand "provisioner" {} ''
      mkdir -p $out
      cp ${./provision.sh} $out/provision.sh
    '';

    pkgs = builtins.foldl' (pkgs: overlay: pkgs.extend overlay) nixpkgs.legacyPackages.${system} [
      hydra.overlays.default
      attic.overlays.default
      nix.overlays.default
    ];
    lib = pkgs.lib;

  in {
    containerImages = let
      defaultTools = with pkgs; [
        coreutils
        findutils
        gnugrep
        gnused
        gnutar
        diffutils
        ps
        less
        curl
        vim
        bashInteractive
        pkgs.dockerTools.binSh
        pkgs.dockerTools.usrBinEnv
        pkgs.dockerTools.caCertificates
      ];
      mkImage = { name, tag, contents, fromImage ? null, users ? {}, groups ? {}, env ? {}, setuid ? []}: pkgs.dockerTools.streamLayeredImage ({
        inherit name tag fromImage;
        contents = contents ++ defaultTools;
        fakeRootCommands = let
          mkGroup = group: ''
            groupadd -f ${group} ${lib.optionalString (groups ? ${group}) "-g ${builtins.toString groups.${group}.gid}"}
          '';
          mkAllGroups = lib.concatMapStrings mkGroup;
          mkUser = username: userinfo: let group = userinfo.group or username; groups = userinfo.groups or []; in ''
            ${mkGroup group}
            ${mkAllGroups groups}
            useradd -g ${group} ${username} ${lib.optionalString (groups != []) "-G ${lib.concatStringsSep "," groups}"} ${lib.optionalString (userinfo ? uid) "-u ${builtins.toString userinfo.uid}"} -p $1$n9vtEYy1$GmsB6rLwOBN7M.dqAdQbp0
            mkdir -p /home/${username}
            chown ${username}:${group} /home/${username}
          '';
          mkAllUsers = lib.concatStrings (lib.mapAttrsToList mkUser users);
          mkSuidBinary = binary: ''
            filepath="$(realpath /bin/${binary})"
            rm /bin/${binary}
            cp "$filepath" /bin/${binary}
            chmod +s /bin/${binary}
          '';
          mkAllSuidBinaries = lib.concatMapStrings mkSuidBinary setuid;
        in ''
          mkdir /tmp
          chmod 1777 /tmp
          ${pkgs.dockerTools.shadowSetup}
          ${mkAllUsers}
          ${mkAllSuidBinaries}
          mkdir -p /imageRoot /nix/var/nix/gcroots/auto
          ln -s /imageRoot /nix/var/nix/gcroots/auto/imageRoot
        '';
        enableFakechroot = true;
        passthru = {
          contents = contents ++ defaultTools;
          imageName = name;
        };
        maxLayers = 125;
        includeNixDB = true;
      });
      in {
      hydra = mkImage {
        name = "rhelmot/hydra";
        tag = "latest";
        contents = with pkgs; [ pkgs.hydra provisionerScript mount umount kubectl postgresql nettools jq openssh bzip2 git pkgs.nix pkgs.attic python3Packages.supervisor cronie ];
        users = {
          hydra = { group = "hydra"; uid = 1000; };
          hydra-queue-runner = { group = "hydra"; uid = 1001; };
          hydra-www = { group = "hydra"; uid = 1002; };
          postgres = { uid = 999; };
          sshd = { uid = 109; };
        } // lib.attrsets.mergeAttrsList (builtins.map (idx: { "nixbld${builtins.toString idx}" = { group = "nixbld"; uid = idx + 30000; groups = [ "nixbld" ]; };}) (lib.range 0 10));
        groups = { nixbld = { gid = 30000; }; };
      };
    };
    imageUploader = pkgs.writeShellScriptBin "image-uploader" (let
        uploadImage = img: ''
          ${img} | docker load
          docker push ${img.imageName}
        '';
      in lib.concatMapStrings uploadImage (lib.attrsets.attrValues self.containerImages));
  };
}
