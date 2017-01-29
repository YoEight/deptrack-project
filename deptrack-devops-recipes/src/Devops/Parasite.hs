{-# LANGUAGE OverloadedStrings #-}
module Devops.Parasite (
    ParasitedHost (..)
  , ParasiteLogin
  , ControlledHost (..)
  , control
  , parasite
  , remoted
  , fileTransferred
  , SshFsMountedDir , sshMounted , sshFileCopy
  , FileTransferred
  ) where

import           Control.Distributed.Closure (Closure)
import           Control.Distributed.Closure (unclosure)
import qualified Data.Binary                 as Binary
import qualified Data.ByteString.Base64.Lazy as B64
import           Data.Monoid                 ((<>))
import           Data.String.Conversions     (convertString)
import           Data.Text                   (Text)
import qualified Data.Text                   as Text
import           Data.Typeable               (Typeable)
import           System.FilePath.Posix       (takeBaseName, (</>))

import           DepTrack
import           Devops.Debian.Commands      hiding (r)
import           Devops.Debian.User          (homeDirPath)
import           Devops.Networking
import           Devops.Storage
import           Devops.Base
import           Devops.Utils

type ParasiteLogin = Text

-- | A host that we control.
data ControlledHost = ControlledHost !ParasiteLogin !Remote

-- | A host that we control.
data ParasitedHost = ParasitedHost !FilePath !ParasiteLogin !IpNetString

-- | A file transferred at a given remote path.
data FileTransferred = FileTransferred !FilePath !Remote

-- | Assert control on a remote.
control :: ParasiteLogin -> DevOp Remote -> DevOp ControlledHost
control login mkRemote = devop fst mkOp $ do
    r@(Remote ip) <- mkRemote
    return ((ControlledHost login r), ip)
  where
    mkOp (ControlledHost _ _, ip) = buildOp ("controlled-host: " <> ip)
                                            ("declares a host is controllable")
                                            noCheck
                                            noAction
                                            noAction
                                            noAction

-- | A parasite reserves a binary in the homedir.
-- TODO: passes a preferences parameters to specialize the parasite protocol.
-- We should shove all of this in the ParasitedHost object.
parasite :: FilePath -> DevOp ControlledHost -> DevOp ParasitedHost
parasite selfPath mkHost = track mkOp $ do
  (ControlledHost login r) <- mkHost
  let selfBinary = preExistingFile selfPath
  let rpath = homeDirPath login </> takeBaseName selfPath
  (FileTransferred _ (Remote ip)) <- fileTransferred selfBinary rpath mkHost
  return (ParasitedHost rpath login ip)

  where mkOp (ParasitedHost _ _ ip) = noop ("parasited-host: " <> ip)
                                           ("copies itself after in a parasite")

-- | Turnup a given DevOp at a given remote.
-- TODO: parametrize protocol and optional remote turndown
remoted :: Typeable a => Closure (DevOp a) -> DevOp ParasitedHost -> DevOp (Remoted a)
remoted clo host = devop fst mkOp $ do
  c <- ssh
  let remoteObj = runDevOp $ unclosure clo
  let fp = convertString $ B64.encode $ Binary.encode clo
  (ParasitedHost rpath login ip) <- host
  return ((Remoted (Remote ip) remoteObj),(rpath, login, c, fp, ip))

  where mkOp (_, (rpath, login, c, b64, ip)) = buildOp
              ("remote-closure: " <> b64 <> " @" <> ip)
              ("calls itself back with `$self turnup --b64=" <> b64 <>"`")
              noCheck
              (blindRun c (sshCmd rpath login ip b64) "")
              noAction
              noAction
        sshCmd rpath login ip b64 = [ "-o", "StrictHostKeyChecking no"
                    , "-o", "UserKnownHostsFile /dev/null"
                    , "-l", Text.unpack login, Text.unpack ip
                    , "sudo", "-E", rpath, "turnup", "--b64", Text.unpack b64]

-- | A file transferred at a remote path.
-- TODO: passes a protocol/preference as parameter for user etc.
fileTransferred :: DevOp FilePresent
                -> FilePath
                -> DevOp ControlledHost
                -> DevOp (FileTransferred)
fileTransferred mkFp path mkHost = devop fst mkOp $ do
  c <- scp
  f <- mkFp
  (ControlledHost login r) <- mkHost
  return (FileTransferred path r, (f,c,login))
  where mkOp (FileTransferred rpath (Remote ip), (FilePresent lpath,c,login)) = do
              buildOp ("remote-file: " <> Text.pack rpath <> "@" <> ip)
                 ("file " <> Text.pack lpath <> " copied on " <> ip)
                 noCheck
                 (blindRun c (scpcmd lpath login ip rpath) "")
                 noAction
                 noAction
        scpcmd lpath login ip rpath = [ "-o", "StrictHostKeyChecking no"
                                , "-o", "UserKnownHostsFile /dev/null"
                                , lpath
                                , Text.unpack login ++ "@" ++ Text.unpack ip ++ ":" ++ rpath]

-- Remote storage mounting.
data SshFsMountedDir = SshFsMountedDir !FilePath

sshMounted :: DevOp DirectoryPresent -> DevOp ControlledHost -> DevOp (SshFsMountedDir)
sshMounted mkPath mkHost = devop fst mkOp $ do
  binmount <- mount
  sshmount <- sshfs
  umount <- fusermount
  (DirectoryPresent path) <- mkPath
  host <- mkHost
  return (SshFsMountedDir path, (host, binmount, sshmount, umount))
  where mkOp (SshFsMountedDir path, (host, binmount, sshmount, umount)) = do
              let (ControlledHost login (Remote ip)) = host
              buildOp ("ssh-fs-dir: " <> Text.pack path <> "@" <> ip)
                 ("mount " <> ip <> " at mountpoint " <> Text.pack path)
                 (checkBinaryExitCodeAndStdout (hasMountLine path)
                                               binmount
                                               ["-l", "-t", "fuse.sshfs"] "")
                 (blindRun sshmount [ Text.unpack login ++ "@" ++ Text.unpack ip ++ ":"
                                    , path
                                    , "-o", "StrictHostKeyChecking=no"
                                    , "-o", "UserKnownHostsFile=/dev/null"
                                    ] "")
                 (blindRun umount [ "-u", path ] "")
                 noAction
        -- | Looks for the filepath in the list of mounts.
        hasMountLine :: FilePath -> String -> Bool
        hasMountLine path dat = elem path $ concatMap words $ lines dat

sshFileCopy :: DevOp FilePresent -> DevOp (SshFsMountedDir) -> DevOp (RepositoryFile, FilePresent)
sshFileCopy mkLocal mkDir = do
  (FilePresent loc) <- mkLocal
  let rpath = (\(SshFsMountedDir dir) -> dir </> takeBaseName loc) <$> mkDir
  fileCopy rpath (mkLocal >>= (\(FilePresent local) -> localRepositoryFile local))