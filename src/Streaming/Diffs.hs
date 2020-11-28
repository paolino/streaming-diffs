{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}

module Streaming.Diffs where

import qualified Data.Map.Monoidal.Strict as M
import qualified Data.Map.Strict as Mn
import Protolude
import Streaming
import Streaming.Internal
import qualified Streaming.Prelude as S

breaker ::
  (Eq t, Monad m) =>
  (a -> t) ->
  Stream (Of a) m r ->
  Stream (Of a) m (Either r (t, Stream (Of a) m r))
breaker _ (Return r) = Return (Left r)
breaker tag s = Effect do
  x <- inspect s
  pure $ case x of
    Left r -> Return (Left r)
    Right (y :> s') -> go (tag y) $ S.cons y s'
  where
    go t' stream =
      Effect do
        x <- inspect stream
        pure case x of
          Left r -> Return $ Right (t', Return r)
          Right (y :> stream') ->
            let t = tag y
             in if t' == t
                  then Step $ y :> go t stream'
                  else Return $ Right (t', Step $ y :> stream')

integrate ::
  (Eq t, Monad m, Monoid b) =>
  Stream (Of (t, b)) m r ->
  Stream (Of (t, b)) m r
integrate stream = Effect $ do
  b :> mr <- S.foldMap snd $ breaker fst stream
  pure $ case mr of
    Left r -> Return r
    Right (t, stream') -> Step $ (t, b) :> integrate stream'

mergeSemigroup :: (Ord t, Monad m, Semigroup b) => Stream (Of (t, b)) m r -> Stream (Of (t, b)) m r -> Stream (Of (t, b)) m (r, r)
mergeSemigroup (Return r) s = (r,) <$> s
mergeSemigroup s (Return r) = (,r) <$> s
mergeSemigroup (Effect m) s = Effect $ m <&> \l -> mergeSemigroup l s
mergeSemigroup s (Effect m) = Effect $ m <&> \r -> mergeSemigroup s r
mergeSemigroup ls@(Step ((lt, lb) :> lr)) rs@(Step ((rt, rb) :> rr))
  | lt < rt = S.yield (lt, lb) >> mergeSemigroup lr rs
  | lt > rt = S.yield (rt, rb) >> mergeSemigroup ls rr
  | otherwise = S.yield (lt, lb <> rb) >> mergeSemigroup lr rr

type LRB a = (Last a, Last a)

mkL :: a -> LRB a
mkL x = (Last $ Just x, mempty)

mkR :: a -> LRB a
mkR y = (mempty, Last $ Just y)

lrb2Update :: Eq v => (Last v, Last v) -> Maybe (Update v)
lrb2Update (Last (Just x), Last (Just y))
  | x == y = Nothing
  | otherwise = Just $ Update x y
lrb2Update (Last (Just x), _) = Just $ Delete x
lrb2Update (_, Last (Just y)) = Just $ New y

streamDiffs ::
  (Monad m, Functor f, Ord t, Monoid (f (LRB a)), Eq a) =>
  Stream (Of (t, f a)) m r ->
  Stream (Of (t, f a)) m r ->
  Stream (Of (t, f (Maybe (Update a)))) m (r, r)
streamDiffs old new =
  S.map (fmap $ fmap lrb2Update) $
    mergeSemigroup (prepare mkL old) (prepare mkR new)
  where
    prepare f = integrate . S.map (fmap $ fmap f)

data Update v = Update v v | Delete v | New v deriving (Show, Eq)

streamAssocsDiffs ::
  (Monad m, Ord t, Ord k, Eq v) =>
  Stream (Of (t, (k, v))) m r ->
  Stream (Of (t, (k, v))) m r ->
  Stream (Of (t, (k, Update v))) m (r, r)
streamAssocsDiffs s1 s2 =
  S.for
    do { streamDiffs (S.map prepare s1) (S.map prepare s2) }
    do \(t, q) -> S.catMaybes $ S.each $ (\(k, v) -> (t,) . (k,) <$> v) <$> M.assocs q
  where
    prepare (t, (k, v)) = (t, M.singleton k v)

preemptive :: Stream (Of Text) IO b  -> Stream (Of Text) IO b
preemptive s = do
  c <- lift $ do
    c <- newEmptyMVar
    forkIO $ void $ S.effects $ S.mapM 
      do  \x -> threadDelay 1_000_000 >> putText ("< " <> x) >> putMVar c x 
      do s
    pure c
  forever $ do
    liftIO (readMVar c) >>= S.yield >> liftIO (takeMVar c) >> pure ()

testPreemptive :: Stream (Of ()) IO ()
testPreemptive = S.mapM (\l -> threadDelay 2_000_000 >> putText ("> " <> l)) $ preemptive $ S.map show $ S.each [1..]
