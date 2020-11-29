{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Streaming.Diffs where

import Control.Arrow (Arrow ((***)))
import qualified Data.Map.Monoidal.Strict as Mn
import qualified Data.Map.Strict as M
import Protolude
import Streaming
import qualified Streaming as S
import Streaming.Internal
import qualified Streaming.Prelude as S

breaker
  :: (Eq t, Monad m)
  => (a -> t)
  -> Stream (Of a) m r
  -> Stream (Of a) m (Either r (t, Stream (Of a) m r))
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

integrate
  :: (Eq t, Monad m, Monoid b)
  => Stream (Of (t, b)) m r
  -> Stream (Of (t, b)) m r
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

streamDiffs
  :: (Monad m, Functor f, Ord t, Monoid (f (LRB a)), Eq a)
  => Stream (Of (t, f a)) m r
  -> Stream (Of (t, f a)) m r
  -> Stream (Of (t, f (Maybe (Update a)))) m (r, r)
streamDiffs old new =
  S.map (fmap $ fmap lrb2Update) $
    mergeSemigroup (prepare mkL old) (prepare mkR new)
  where
    prepare f = integrate . S.map (fmap $ fmap f)

data Update v = Update v v | Delete v | New v deriving (Show, Eq)

streamAssocsDiffs
  :: (Monad m, Ord t, Ord k, Eq v)
  => Stream (Of (t, (k, v))) m r
  -> Stream (Of (t, (k, v))) m r
  -> Stream (Of (t, (k, Update v))) m (r, r)
streamAssocsDiffs s1 s2 =
  S.for
    do streamDiffs (S.map prepare s1) (S.map prepare s2)
    do \(t, q) -> S.catMaybes $ S.each $ (\(k, v) -> (t,) . (k,) <$> v) <$> M.assocs q
  where
    prepare (t, (k, v)) = (t, M.singleton k v)

preemptive :: MonadIO m => Stream (Of a) IO b -> Stream (Of a) m b
preemptive s = do
  c <- liftIO $ do
    c <- newEmptyMVar
    forkIO $
      void $
        S.effects $ S.chain
          do putMVar c
          do s
    pure c
  forever $ do
    liftIO (readMVar c) >>= S.yield >> liftIO (takeMVar c) >> pure ()

testPreemptive :: Stream (Of ()) IO ()
testPreemptive =
  S.mapM
    do \o -> threadDelay 2_000_000 >> putText ("output " <> o)
    do
      preemptive $ S.chain
        do \i -> threadDelay 1_000_000 >> putText ("input " <> i)
        do S.map show $ S.each [1 ..]

preemptiveOut :: (a -> IO ()) -> Stream (Of a) IO b -> Stream (Of a) IO b
preemptiveOut out s = do
  c <- liftIO $ do
    c <- newEmptyMVar
    forkIO $ forever do
      x <- readMVar c
      out x
      void $ takeMVar c
    pure c
  S.chain
    do putMVar c
    do s

groupBatch :: (Ord k, Monad m) 
  => Int -- ^ batch size 
  -> (a -> (k, c))  -- ^ bucket selection
  -> Stream (Of a) m b  
  -> Stream (Of (k, [c])) m b
groupBatch dumpSize bucket = go mempty
  where
    go m s = effect do
      x <- S.inspect s
      pure $ case x of
        Left b -> S.each (M.assocs $ reverse . snd <$> m) >> pure b
        Right (x :> s') ->
          let (k, y) = bucket x
              (l, ys) = (succ *** (y :)) $ fromMaybe (0, []) $ M.lookup k m
           in if l >= dumpSize
                then S.yield (k, reverse ys) >> go (M.delete k m) s'
                else go (M.insert k (l, ys) m) s'
