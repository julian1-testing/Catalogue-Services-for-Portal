-- stack --install-ghc --resolver lts-5.13 runghc --package http-conduit

-- {-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Arrows, NoMonomorphismRestriction #-}

-- needed for disambiguating types,
{-# LANGUAGE ScopedTypeVariables, OverloadedStrings #-}

{-# LANGUAGE QuasiQuotes #-}


import Text.XML.HXT.Core

import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types.Status (statusCode)

-- TODO import qualified
import Network.HTTP.Types.Method
import Network.HTTP.Types.Header

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import qualified Data.ByteString.Lazy.Char8 as BLC


import Database.PostgreSQL.Simple

import Text.RawString.QQ

import Data.Char (isSpace)

{-
  catalogue-imos, pot, and WMS
  https://github.com/aodn/chef-private/blob/master/data_bags/imos_webapps_geonetwork_harvesters/catalogue_imos.json
-}

-- import qualified Prelude as P


parseXML s = readString [ withValidate no
    , withRemoveWS yes  -- throw away formating WS
    ] s


atTag tag = deep (isElem >>> hasName tag)


-- limit to just the wms/wfs stuff.
--



doHTTPGET url = do
    let settings = tlsManagerSettings { managerResponseTimeout = responseTimeoutMicro $ 60 * 1000000 }
    manager <- newManager settings
    request <- parseRequest url
    response <- httpLbs request manager
    -- Prelude.putStrLn $ "The status code was: " ++ (show $ statusCode $ responseStatus response)
    return response




-- IMPORTANT must close!!!
-- responseClose :: Response a -> IO () 

doHTTPPost url body = do
    let settings = tlsManagerSettings  {
        managerResponseTimeout = responseTimeoutMicro $ 60 * 1000000
    }
    manager <- newManager settings
    -- get initial request
    initialRequest <- parseRequest url
    -- modify for post
    let request = initialRequest {
        method = BC.pack "POST",
        requestBody = RequestBodyBS $ BC.pack body,
        requestHeaders = [
            (hContentType, BC.pack "application/xml")
        ]
    }
    response <- httpLbs request manager
    Prelude.putStrLn $ "The status code was: " ++ (show $ statusCode $ responseStatus response)
    return response


parseIdentifiers = atTag "csw:SummaryRecord" >>>
  proc l -> do
    identifier <- getChildren >>> hasName "dc:identifier" >>> getChildren >>> getText -< l
    title      <- getChildren >>> hasName "dc:title" >>> getChildren >>> getText -< l
    returnA -< (identifier, title)


-- QuasiQuotes may be cleaner,
-- http://kseo.github.io/posts/2014-02-06-multi-line-strings-in-haskell.html
-- alternatively use the xml constructor stuff from HXT
getRecordsQuery :: String
getRecordsQuery = unlines [
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
    "<csw:GetRecords xmlns:csw=\"http://www.opengis.net/cat/csw/2.0.2\" service=\"CSW\" version=\"2.0.2\"    ",
    "    resultType=\"results\" startPosition=\"1\" maxRecords=\"5\" outputFormat=\"application/xml\"  >",
    "  <csw:Query typeNames=\"csw:Record\">",
    "    <csw:Constraint version=\"1.1.0\">",
    "      <Filter xmlns=\"http://www.opengis.net/ogc\" xmlns:gml=\"http://www.opengis.net/gml\">",
    "        <PropertyIsLike wildCard=\"%\" singleChar=\"_\" escape=\"\\\">",
    "          <PropertyName>AnyText</PropertyName>",
    "          <Literal>%</Literal>",
    "        </PropertyIsLike>",
    "      </Filter>",
    "    </csw:Constraint>",
    "  </csw:Query>",
    "</csw:GetRecords>" 
    ]


-- TODO need to think about the transaction boundary

-- Also partially bind in the parameters like conn?
-- or pass in the processing function... eg. continuation passing style 

-- might use a tuple arg, ...

doCSWGetRecords conn = do
    -- retrieve all record items
    let url = "https://catalogue-portal.aodn.org.au/geonetwork/srv/eng/csw"
    response <- doHTTPPost url getRecordsQuery
    let s = BLC.unpack $ responseBody response

    -- parse out the metadata identifier/title  
    -- TODO add description
    identifiers <- runX (parseXML s  >>> parseIdentifiers)

    -- print the records,
    let formattedlst = Prelude.map (\(identifier,title) -> identifier ++ " -> " ++ title) identifiers 
    mapM putStrLn formattedlst

    -- store to db
    let storeToDB (identifier,title) = execute conn "insert into catalog(uuid,title) values (?, ?)" [identifier, title]
    mapM storeToDB identifiers

    -- further process each record,
    mapM (\(identifier,title) -> doCSWGetRecordById conn identifier title) identifiers 
    putStrLn "finished"




-- https://catalogue-portal.aodn.org.au/geonetwork/srv/eng/csw?request=GetRecordById&service=CSW&version=2.0.2&elementSetName=full&id=4402cb50-e20a-44ee-93e6-4728259250d2&outputSchema=http://www.isotc211.org/2005/gmd
-- ok now we want to go through the actual damn records,


parseOnlineResources = atTag "gmd:CI_OnlineResource" >>>
  proc l -> do
    -- leagName <- getAttrValue "NAME"   -< l
    protocol <- atTag "gmd:protocol" >>> getChildren >>> hasName "gco:CharacterString" >>> getChildren >>> getText -< l
    url      <- atTag "gmd:linkage"  >>> getChildren >>> hasName "gmd:URL" >>> getChildren >>> getText -< l
    returnA -< (protocol, url)

-- https://catalogue-portal.aodn.org.au/geonetwork/srv/eng/csw?request=GetRecordById&service=CSW&version=2.0.2&elementSetName=full&id=0a21e0b9-8acb-4dc2-8c82-57c3ea94dd85&outputSchema=http://www.isotc211.org/2005/gmd

parseDataParameters = atTag "mcp:dataParameter" >>>
  proc l -> do
    term <- atTag "mcp:DP_DataParameter" 
      >>> getChildren >>> hasName "mcp:parameterName" 
      >>> getChildren >>> hasName "mcp:DP_Term" -< l

    txt <- getChildren >>> hasName "mcp:term"  >>> getChildren >>> hasName "gco:CharacterString" >>> getChildren >>> getText -< term
    url <- getChildren >>> hasName "mcp:vocabularyTermURL"  >>> getChildren >>> hasName "gmd:URL" >>> getChildren >>> getText -< term

    returnA -< (txt, url) 


-- Or combine the parsing, and the sql actions.
-- we need to have the vocab imported - before we can do the lookups.
-- only need broader and narrower,

-- use hask. rdf library, or sql. - shouldn't be too hard to capture this stuff relationally. it's just one table.

-- TODO separate out retrieving the record and decoding the xml document,.
-- eg. separate out the online resource from the facet search term stuff.

-- function is wrongly named, since it is decoding the online resources also,  
-- should we pass both title the uuid 





-- trim :: String -> String
-- trim = f . f
--   where f = reverse . dropWhile isSpace
stripSpace = filter $ not.isSpace


getCSWGetRecordById uuid title = do
    -- retrieve record
    putStrLn $ title ++ uuid

    -- let url = "https://catalogue-portal.aodn.org.au/geonetwork/srv/eng/csw?request=GetRecordById&service=CSW&version=2.0.2&elementSetName=full&id=" ++ uuid ++ "&outputSchema=http://www.isotc211.org/2005/gmd"

    let url = stripSpace $ [r| 
      https://catalogue-portal.aodn.org.au
      /geonetwork/srv/eng/csw
      ?request=GetRecordById
      &service=CSW
      &version=2.0.2
      &elementSetName=full
      &outputSchema=http://www.isotc211.org/2005/gmd
      &id= |] ++ uuid 

    putStrLn url

    response <- doHTTPGET url
    putStrLn $ "  The status code was: " ++ (show $ statusCode $ responseStatus response)
    -- s <- BLC.unpack $ responseBody response

    let s = BLC.unpack $ responseBody response
    putStrLn s
    return s



doCSWGetRecordById conn uuid title = do
    -- retrieve record
    putStrLn $ title ++ uuid
    -- let url = "https://catalogue-portal.aodn.org.au/geonetwork/srv/eng/csw?request=GetRecordById&service=CSW&version=2.0.2&elementSetName=full&id=" ++ uuid ++ "&outputSchema=http://www.isotc211.org/2005/gmd"

    let url = [r| 
      https://catalogue-portal.aodn.org.au
      /geonetwork/srv/eng/csw
      ?request=GetRecordById
      &service=CSW
      &version=2.0.2
      &elementSetName=full
      &id= |] ++ uuid ++ [r| 
      &outputSchema=http://www.isotc211.org/2005/gmd
    |]



    putStrLn url

    response <- doHTTPGET url
    putStrLn $ "  The status code was: " ++ (show $ statusCode $ responseStatus response)
    let s = BLC.unpack $ responseBody response

    -- parse for resources,
    onlineResources <- runX (parseXML s  >>> parseOnlineResources)
    -- print resources
    let lst = Prelude.map (\(protocol,url) -> "  " ++ protocol ++ " -> " ++ url) onlineResources
    mapM putStrLn lst

    putStrLn "###############"
    putStrLn "parsing the parameters"

    -- parse data parameters,
    dataParameters <- runX (parseXML s  >>> parseDataParameters)

    putStrLn $  (show. length) dataParameters
 
    let lst = Prelude.map (\term -> show term ) dataParameters
    mapM putStrLn lst

   

    -- store resources to db
--    let storeToDB (protocol,url) = execute conn "insert into resource(catalog_id,protocol,linkage) values ((select id from catalog where uuid = ?), ?, ?)" [uuid, protocol, url]
--    mapM storeToDB onlineResources

    putStrLn "  finished"


-- So how do we do this...
-- get the data - then store in sql?  can probably do it. relationally...
-- update...
-- 



main :: IO ()
main = do
  conn <- connectPostgreSQL "host='postgres.localnet' dbname='harvest' user='harvest' sslmode='require'"
  -- execute conn "truncate resource;"  ()
  -- note that the sequence will update - 
  execute conn "truncate catalog, resource;"  ()

  -- doCSWGetRecords conn
  -- https://github.com/aodn/chef-private/blob/master/data_bags/imos_webapps_geonetwork_harvesters/catalogue_imos.json  
  -- actually 

  record <- getCSWGetRecordById "4402cb50-e20a-44ee-93e6-4728259250d2" "my argo"
  
  return ()

