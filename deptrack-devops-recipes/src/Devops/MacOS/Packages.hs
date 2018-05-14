{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses #-}

{-# OPTIONS_GHC -fno-warn-orphans #-}

module Devops.MacOS.Packages where

import Devops.Base
import Devops.Binary (HasBinary)
import Devops.MacOS.Base

docker :: DevOp env (HomebrewPackage "docker")
docker = homebrewPackage

instance HasBinary (HomebrewPackage "docker") "docker" where

graphviz :: DevOp env (HomebrewPackage "graphviz")
graphviz = homebrewPackage

instance HasBinary (HomebrewPackage "graphviz") "dot" where
instance HasBinary (HomebrewPackage "graphviz") "neato" where
instance HasBinary (HomebrewPackage "graphviz") "twopi" where
