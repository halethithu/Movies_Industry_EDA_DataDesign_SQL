USE Movies;
GO

/*** 
Step 1: Exploring raw data

SELECT * FROM [dbo].[AllMovies]; -- 7,668

Missing data (NULL)
- Gross: 189 (2.5%) --> remove; 7,479 left
- Budget: 2,171 (28.3%) --> remove the field
- Name, genre, year, director, releaseddate: 0
- Rating: 54
- Country: 1
- Company: 10
- Writer: 3
- Runtime: 1 (One for the Money) --> 91 min 

Data consistency:
- Released date: string, came with country --> Take out date and change datatype to date
- Rating --> US current system

https://www.kaggle.com/datasets/danielgrijalvas/movies
https://www.imdb.com/
https://en.wikipedia.org/wiki/Motion_picture_content_rating_system
https://en.wikipedia.org/wiki/Motion_Picture_Association_film_rating_system

****/

/*
CREATE SCHEMA stg;
GO
CREATE SCHEMA dim;
GO
CREATE SCHEMA fact;
GO
CREATE SCHEMA vw;
GO
*/

/*** Step 2: Cleansing data ***/

DROP TABLE if exists stg.ValidMovies;
GO
SELECT *
INTO stg.ValidMovies
FROM [dbo].[AllMovies]
WHERE gross is NOT NULL
;
GO


DROP TABLE if exists stg.Movies;
GO

WITH MovieCTE
AS
(
	SELECT ROW_NUMBER () OVER (ORDER BY [name]) as MovieID
	  ,[name]
      , (CASE
				WHEN rating in ('G') THEN rating
				WHEN rating in ('TV-PG', 'PG') THEN 'PG'
				WHEN rating in ('TV-14','PG-13') THEN 'PG-13'			
				WHEN rating in ('Approved', 'X', 'R','18A') THEN 'R'
				WHEN rating in ('TV-MA', 'A', 'NC-17') THEN 'NC-17'
				WHEN rating in ('Not Rated','Unrated') THEN 'NR'	
				WHEN rating is NULL THEN 'Unknown'
				ELSE 'err'
				END) as rating

      ,[genre]
      ,[year]
	  ,cast(left(released,CHARINDEX('(', released)-1) as date) as 'ReleasedDate'
      ,[score]
      ,[votes]
      ,[director]
      ,ISNULL([writer], 'Unknown') as Writer
      ,[star]
      ,ISNULL([country],'Unknown') as Country
      ,[gross]
      ,ISNULL([company], 'Unknown') as Company
	  ,ISNULL(runtime, '91') as RunTime

	FROM [dbo].[AllMovies]
	WHERE gross is NOT NULL
)

SELECT *
	, (CASE
					WHEN RunTime BETWEEN 55 AND 120 THEN '55-120'
					WHEN runtime BETWEEN 121 AND 180 THEN '121-180'
					WHEN runtime BETWEEN 181 AND 366 THEN '181-366'
					--WHEN runtime BETWEEN 241 AND 366 THEN '241-366'
					ELSE 'err'
					END) as RunTimeGroup
INTO stg.Movies
FROM MovieCTE;
;
GO

-- Update runtime of 1 movies: UPDATE stg.Movies SET runtime = '91' WHERE MovieID = 4016

/* Check NULL values:
SELECT *
FROM [stg].[Movies]
WHERE rating is NULL; -- 7,479
*/


/*** Step 3: Building fact and dimension tables and views ***/

/**PructionTeam Dimension Table**/

DROP TABLE if exists stg.ProductionTeam;
GO

SELECT distinct [Company] --7372
	  ,[Director]
      ,[Writer]
      ,[Star]	  
      ,[Country]
INTO stg.ProductionTeam
FROM [stg].[Movies]
;
GO

DROP TABLE if exists dim.ProductionTeam;
GO

SELECT ROW_NUMBER () OVER (ORDER BY Company, Director, Writer, Star, Country) as ProductionID
	  ,[Company] 
	  ,[Director]
      ,[Writer]
      ,[Star]	  
      ,[Country]
INTO dim.ProductionTeam
FROM stg.ProductionTeam

GO

/** Rating Dimension Table**/

DROP TABLE if exists stg.Rating;
GO

SELECT distinct Rating
INTO stg.Rating
FROM [stg].[Movies];
GO


DROP TABLE if exists dim.Rating;
GO
SELECT ROW_NUMBER() OVER (ORDER BY Rating) + 1000 as RatingID
	, Rating
INTO dim.Rating
FROM stg.Rating
;
GO

/** Genre Table**/

DROP TABLE if exists stg.Genre;
GO

SELECT distinct Genre
INTO stg.Genre
FROM [stg].[Movies];
GO

DROP TABLE if exists dim.Genre;
GO

SELECT ROW_NUMBER() OVER (ORDER BY Genre) + 10000 as GenreID
	,Genre
INTO dim.Genre
FROM stg.Genre
;
GO

/** Genre Table**/

DROP TABLE if exists stg.Runtime;
GO

SELECT distinct RunTimeGroup
INTO stg.Runtime
FROM [stg].[Movies]
;
GO

DROP TABLE if exists dim.RunTime;
GO

SELECT ROW_NUMBER() OVER (ORDER BY RunTimeGroup) + 1000 as RunTimeID
	,RunTimeGroup
INTO dim.RunTime
FROM stg.Runtime
;
GO


/*** dim. Calendar***/
DROP TABLE if exists dim.Calendar;
GO

DECLARE @StartDate  date = '19800101'; -- 

DECLARE @CutoffDate date = DATEADD(DAY, -1, DATEADD(YEAR, 41, @StartDate)); 

;WITH seq(n) AS 

(
  SELECT 0 UNION ALL SELECT n + 1 FROM seq 
  WHERE n < DATEDIFF(DAY, @StartDate, @CutoffDate)
),
d(d) AS  
(
  SELECT DATEADD(DAY, n, @StartDate) FROM seq
),
src AS 
(
  SELECT
    Date         = CONVERT(date, d),
    Month        = DATEPART(MONTH,     d),
    MonthName    = DATENAME(MONTH,     d),
    Quarter      = DATEPART(Quarter,   d),
    Year         = DATEPART(YEAR,      d),
	WeekendFlag	 = (CASE
					WHEN DATENAME(WEEKDAY, d) in ('Saturday','Sunday') THEN '1'
					ELSE '0'
					END),
	Decade		 = (CASE
					WHEN DATEPART(YEAR,d) BETWEEN 1980 AND 1989 THEN '1980'
					WHEN DATEPART(YEAR,d) BETWEEN 1990 AND 1999 THEN '1990'
					WHEN DATEPART(YEAR,d) BETWEEN 2000 AND 2009 THEN '2000'
					WHEN DATEPART(YEAR,d) BETWEEN 2010 AND 2019 THEN '2010'
					ELSE '2020'
					END)
    
  FROM d
)
SELECT * 
INTO dim.Calendar
FROM src
  ORDER BY Date
  OPTION (MAXRECURSION 0);

GO

/*** Fact Table ***/

DROP TABLE if exists fact.Movies;
GO

SELECT m.MovieID
	, m.[name] as MovieName
	, m.ReleasedDate
	, g.GenreID
	, r.RatingID
	, p.ProductionID
	, rt.RunTimeID
	, round(m.score,2) as Score
	, m.Votes
	, m.Runtime
	, round(m.gross,0) as GrossRevenue
INTO fact.Movies
FROM [stg].[Movies] m
	INNER JOIN dim.[Rating] r
	ON m.Rating = r.Rating
	INNER JOIN [dim].[Genre] g
	ON m.Genre = g.Genre
	INNER JOIN [dim].[ProductionTeam] p
	ON m.company = p.Company
		AND m.director = p.Director
		AND m.writer = p.Writer
		AND m.star = p.Star
		AND m.country = p.Country
	INNER JOIN [dim].[RunTime] rt
	ON m.RunTimeGroup = rt.RunTimeGroup
;
GO

/*** View Building***/

CREATE OR ALTER VIEW vw.dProductionTeam
AS

SELECT *
FROM [dim].[ProductionTeam]
;
GO

CREATE OR ALTER VIEW vw.dGenre
AS

SELECT *
FROM [dim].[Genre]
;
GO

CREATE OR ALTER VIEW vw.dRunTime
AS

SELECT *
FROM [dim].RunTime
;
GO

CREATE OR ALTER VIEW vw.dRating
AS

SELECT *
FROM [dim].[Rating]
;
GO

CREATE OR ALTER VIEW vw.dCalendar
AS

SELECT *
FROM [dim].[Calendar]
;
GO

CREATE OR ALTER VIEW vw.Fact
AS

SELECT *
FROM [fact].[Movies]
;
GO

/*** Step 4: Validate model

SELECT f.MovieName
	, cal.[Year]
	, g.Genre
	, p.Company
	, r.Rating
	, rt.RunTimeGroup
	, f.Score
	, f.Votes
	, f.GrossRevenue
FROM [vw].[Fact] f --7,479
	INNER JOIN [vw].[dCalendar] cal
	ON f.ReleasedDate = cal.Date
	INNER JOIN [vw].[dGenre] g
	ON f.GenreID = g.GenreID
	INNER JOIN [vw].[dProductionTeam] p
	ON f.ProductionID = p.ProductionID
	INNER JOIN [vw].[dRating] r
	ON f.RatingID = r.RatingID
	INNER JOIN [vw].[dRunTime] rt
	ON f.RunTimeID = rt.RunTimeID
ORDER BY f.GrossRevenue DESC
;
*/
