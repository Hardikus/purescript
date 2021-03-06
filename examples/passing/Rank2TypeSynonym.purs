module Main where

import Control.Monad.Eff

type Foo a = forall f. (Monad f) => f a

foo :: forall a. a -> Foo a
foo x = pure x

bar :: Foo Number
bar = foo 3.0

main = do
  x <- bar
  Debug.Trace.print x
