import Streaming.Diffs
import Test.Hspec
import Test.QuickCheck

pureDiffs :: [(Int, (Int, Int))] -> [(Int, (Int, Int))] -> [(Int, (Int, Update Int))]
pureDiffs s1 s2 =
  let m1 = Mn.fromList $ fmap (\(t, (k, v)) -> ((t, k), v)) s1
      m2 = Mn.fromList $ fmap (\(t, (k, v)) -> ((t, k), v)) s2
      delete = Delete <$> Mn.difference m1 m2
      new = New <$> Mn.difference m2 m1
      update = Mn.intersectionWith Update m1 m2
   in fmap (\((t, k), v) -> (t, (k, v))) $
        filter \case
          (_, Update v1 v2) -> v1 /= v2
          _ -> True
          $ Mn.assocs (delete <> update <> new)

randomList :: Int -> Gen [(Int, (Int, Int))]
randomList r = do
  l :: Int <- choose (1, r)
  let next l' n m x
        | l' == l = pure []
        | otherwise = do
          cn <- elements [False, False, False, True] -- time speed
          cd <- choose (1, 2)
          let (n', m') = if cn then (n + cd, cd - 1) else (n, m + 1)
          cm <- elements [False, False, True]
          cd <- choose (1, 2)
          let (m'', x') = if cm then (m' + cd, cd - 1) else (m', x)
          cx <- elements [False, False, False, True]
          cd <- choose (1, 2)
          let x'' = if cx then x' + cd else x'
          ((n', (m'', x'')) :) <$> next (l' + 1) n' m'' x''
  next 0 0 0 0

testDiffs :: [(Int, (Int, Int))] -> [(Int, (Int, Int))] -> [(Int, (Int, Update Int))]
testDiffs s1 s2 =
  let ls :> _ = runIdentity $ S.toList $ streamAssocsDiffs @Identity (S.each s1) (S.each s2)
   in ls

reverseDiff :: Update v -> Update v
reverseDiff (Delete x) = New x
reverseDiff (New x) = Delete x
reverseDiff (Update x y) = Update y x

main :: IO ()
main = hspec do
  describe "streamDiffs" do
    it "gets no diffs for same stream" $
      shouldBe
        do pureDiffs [(1, (1, 1))] [(1, (1, 1))]
        do []
    it "gets deletes for left stream " $
      shouldBe
        do pureDiffs [(1, (1, 1))] []
        do [(1, (1, Delete 1))]
    it "gets news for right stream " $
      shouldBe
        do pureDiffs [] [(1, (1, 1))]
        do [(1, (1, New 1))]
    it "gets delete news for uncrossing streams " $
      shouldBe
        do pureDiffs [(1, (1, 1))] [(2, (1, 1))]
        do [(1, (1, Delete 1)), (2, (1, New 1))]
    it "gets Updates for different crossing streams" $
      shouldBe
        do pureDiffs [(1, (1, 1))] [(1, (1, 2))]
        do [(1, (1, Update 1 2))]
    it "gets no diffs for same stream" $
      shouldBe
        do testDiffs [(1, (1, 1))] [(1, (1, 1))]
        do []
    it "gets deletes for left stream " $
      shouldBe
        do testDiffs [(1, (1, 1))] []
        do [(1, (1, Delete 1))]
    it "gets news for right stream " $
      shouldBe
        do testDiffs [] [(1, (1, 1))]
        do [(1, (1, New 1))]
    it "gets delete news for uncrossing streams " $
      shouldBe
        do testDiffs [(1, (1, 1))] [(2, (1, 1))]
        do [(1, (1, Delete 1)), (2, (1, New 1))]
    it "gets Updates for different crossing streams" $
      shouldBe
        do testDiffs [(1, (1, 1))] [(1, (1, 2))]
        do [(1, (1, Update 1 2))]
    it "match the pure implementation" $
      property $
        forAll ((,) <$> randomList 1000 <*> randomList 1000) $ \(l1, l2) -> shouldBe
          do pureDiffs l1 l2
          do testDiffs l1 l2
    it "switching list reverses siffs " $
      property $
        forAll ((,) <$> randomList 1000 <*> randomList 1000) $ \(l1, l2) -> shouldBe
          do testDiffs l1 l2
          do fmap (fmap reverseDiff) <$> testDiffs l2 l1
