-- stack --install-ghc --resolver lts-5.13 runghc --package http-conduit

-- {-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Arrows, NoMonomorphismRestriction #-}

-- needed for disambiguating types,
{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}

{-# LANGUAGE QuasiQuotes #-}

import Text.XML.HXT.Core

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC

import Database.PostgreSQL.Simple

import Text.RawString.QQ

-- TODO change name - load-vocab-scheme?

{-
  http://vocabs.ands.org.au/repository/api/lda/aodn/aodn-discovery-parameter-vocabulary/version-1-2/resource.xml?uri=http://vocab.aodn.org.au/def/discovery_parameter/894

  http://vocab.aodn.org.au/def/discovery_parameter/894

  Concentration of inferred chlorophyll from relative fluorescence per unit volume of the water body

  https://s3-ap-southeast-2.amazonaws.com/content.aodn.org.au/Vocabularies/parameter-category/aodn_aodn-parameter-category-vocabulary.rdf

-}

parseXML s = readString [ withValidate no
    , withRemoveWS yes  -- throw away formating WS
    ] s


isDescription = do
  isElem >>> hasName "rdf:Description"


isCoreScheme = do
  getChildren
  >>> hasName "rdf:type"
  >>> getAttrValue "rdf:resource"
  >>> isA ((==) "http://www.w3.org/2004/02/skos/core#ConceptScheme")



isCoreConcept = do
  getChildren
  >>> hasName "rdf:type"
  >>> getAttrValue "rdf:resource"
  >>> isA ((==) "http://www.w3.org/2004/02/skos/core#Concept")





--------------------------
-- Conceptscheme stuff
-- we store the conceptscheme as a concept since it makes dealing with concepts and their parent 
-- relationships a lot easier.
-- need to change the name

parseScheme =
  deep (isElem >>> hasName "rdf:Description") >>>
  proc e -> do
    isCoreScheme -< e
    about <- getAttrValue "rdf:about" -< e
    title <- getChildren >>> hasName "dcterms:title" >>> getChildren >>> getText -< e
    -- description, etc.
    returnA -< (about, title)





storeSchemes conn s = do
    schemes <- runX (parseXML s  >>> parseScheme)
    -- mapM (putStrLn.show) schemes
    putStrLn $ "  scheme count " ++ (show.length) schemes
    mapM store schemes
    where
      -- query = "insert into scheme(url,title) values (?, ?)"
      query = "insert into concept(url,label) values (?, ?)"
      -- TODO - make it a tuple instead... of array
      store (url,title) = execute conn query [url, title]





--------------------------
-- concept stuff

parseConcept =
  deep (isElem >>> hasName "rdf:Description") >>>
  proc e -> do
    isCoreConcept -< e
    about <- getAttrValue "rdf:about" -< e
    prefLabel <- getChildren >>> hasName "skos:prefLabel" >>> getChildren >>> getText -< e
    returnA -< (about, prefLabel)


storeConcepts conn s = do
    concepts <- runX (parseXML s  >>> parseConcept)
    -- mapM (putStrLn.show) concepts
    putStrLn $ "  concept count " ++ (show.length) concepts
    -- store to db
    mapM store concepts
    where
    -- TODO tuple not array
      query = "insert into concept(url,label) values (?, ?)"
      store (url,label) = execute conn query [url, label]


--------------------------
-- narrower

parseNarrower =
  deep isDescription >>>
  proc e -> do
    isCoreConcept -< e
    resource <- getAttrValue "rdf:about" -< e
    narrower <- getChildren >>> isElem >>> hasName "skos:narrower" >>> getAttrValue "rdf:resource" -< e
    returnA -< (resource, narrower)


storeNarrower conn s = do
    narrower <- runX (parseXML s >>> parseNarrower)
    -- mapM (putStrLn.show) narrower
    putStrLn $ "  narrower count " ++ (show.length) narrower
    mapM store narrower
    where
      query = [r|
        insert into narrower(concept_id, narrower_id)
        values (
          (select id from concept where concept.url = ?),
          (select id from concept where concept.url = ?)
        )
      |]
      -- TODO tuple not array
      store (url,narrower_url) = execute conn query [url, narrower_url]


--------------------------
-- narrowMatch

parseNarrowMatch =
  deep isDescription >>>
  proc e -> do
    isCoreConcept -< e
    resource <- getAttrValue "rdf:about" -< e
    narrowMatch <- getChildren >>> isElem >>> hasName "skos:narrowMatch" >>> getAttrValue "rdf:resource" -< e
    returnA -< (resource, narrowMatch)


storeNarrowMatchs conn s = do
    narrowMatch <- runX (parseXML s >>> parseNarrowMatch)
    -- mapM (putStrLn.show) narrowMatch
    putStrLn $ "  narrowMatch count " ++ (show.length) narrowMatch
    mapM store narrowMatch
    where
      query = [r|
        insert into narrow_match(concept_id, narrower_id)
        values (
          (select id from concept where concept.url = ?),
          (select id from concept where concept.url = ?)
        )
      |]
      store (url,narrower_url) = execute conn query [url, narrower_url]


-----------
-- scheme top concept
-- parse out the relationships between scheme and the top concepts

parseSchemeHasTopConcept =
  deep (isElem >>> hasName "rdf:Description") >>>
  proc e -> do
    -- IMPORTANT - can we move the predicate up into the parent...
    -- for everything...
    isCoreScheme -< e
    resource <- getAttrValue "rdf:about" -< e
    hasTopConcept <- getChildren >>> hasName "skos:hasTopConcept" >>> getAttrValue "rdf:resource" -< e
    -- description, etc.
    returnA -< (resource, hasTopConcept)



storeSchemeHasTopConcept conn s = do
    schemes <- runX (parseXML s  >>> parseSchemeHasTopConcept)
    mapM (putStrLn.show) schemes
    -- putStrLn $ "  schemeHasTopConcept count " ++ (show.length) schemes
    mapM store schemes
    where
      query = [r|
        insert into scheme_has_top_concept(scheme_id, concept_id)
        values (
          (select id from concept where concept.url = ?),
          (select id from concept where concept.url = ?)
        )
      |]
      store (url,other_url) = execute conn query [other_url, url]



--------------------------
-- scheme membership
--	<skos:inScheme rdf:resource="http://vocab.aodn.org.au/def/discovery_parameter/1"/>

{-
parseInScheme =
  deep isDescription >>>
  proc e -> do
    isCoreConcept -< e
    resource <- getAttrValue "rdf:about" -< e
    inScheme <- getChildren >>> isElem >>> hasName "skos:inScheme" >>> getAttrValue "rdf:resource" -< e
    returnA -< (resource, inScheme)


storeInScheme conn s = do
    inScheme <- runX (parseXML s >>> parseInScheme)
    -- mapM (putStrLn.show) inScheme
    putStrLn $ "  inScheme count " ++ (show.length) inScheme
    mapM store inScheme
    where
      query = [r|
        insert into in_scheme(concept_id, scheme_id)
        values (
          (select id from concept where concept.url = ?),
          (select id from scheme where scheme.url = ?)
        )
      |]
      store (url,inScheme_url) = execute conn query [url, inScheme_url]

-}



--------------------------
-- store everything

storeAll conn vocab vocabCategory = do
  -- TODO change name

  storeSchemes conn  vocab
  storeSchemes conn vocabCategory


  storeConcepts conn vocab
  storeConcepts conn vocabCategory

  -- we need to make sure we are 
  storeSchemeHasTopConcept conn vocab
  storeSchemeHasTopConcept conn vocabCategory


  -- storeInScheme conn  vocab
  -- storeInScheme conn vocabCategory

  storeNarrowMatchs conn vocab
  storeNarrowMatchs conn vocabCategory

  storeNarrower conn vocab
  storeNarrower conn vocabCategory




--------------------------


main :: IO ()
main = do
  conn <- connectPostgreSQL "host='postgres.localnet' dbname='harvest' user='harvest' sslmode='require'"

  -- should we be using plural?
  -- cannot rebuild the facets from out under - actually we can we just need to reindex,..
--  execute conn "truncate record, facet, resource,  scheme, concept, narrower, narrow_match, in_scheme ;" ()
  execute conn "truncate record, facet, resource,  concept, narrower, narrow_match, scheme_has_top_concept ;" ()

  -- platform
  print "doing platform"
  platform <- readFile "./vocab/aodn_aodn-platform-vocabulary.rdf"
  platformCategory <- readFile "./vocab/aodn_aodn-platform-category-vocabulary.rdf"
  storeAll conn platform platformCategory


  -- parameter
  print "doing parameter"
  param         <- readFile "./vocab/aodn_aodn-discovery-parameter-vocabulary.rdf"
  paramCategory <- readFile "./vocab/aodn_aodn-parameter-category-vocabulary.rdf"
  storeAll conn param paramCategory


  -- are there any other resources?
  close conn
  putStrLn "finished"

