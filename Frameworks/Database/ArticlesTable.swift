//
//  ArticlesTable.swift
//  Evergreen
//
//  Created by Brent Simmons on 5/9/16.
//  Copyright © 2016 Ranchero Software, LLC. All rights reserved.
//

import Foundation
import RSCore
import RSDatabase
import RSParser
import Data

final class ArticlesTable: DatabaseTable {

	let name: String
	private let accountID: String
	private let queue: RSDatabaseQueue
	private let statusesTable: StatusesTable
	private let authorsLookupTable: DatabaseLookupTable
	private let attachmentsLookupTable: DatabaseLookupTable
	private let tagsLookupTable: DatabaseLookupTable

	// TODO: update articleCutoffDate as time passes and based on user preferences.
	private var articleCutoffDate = NSDate.rs_dateWithNumberOfDays(inThePast: 3 * 31)!
	private var maximumArticleCutoffDate = NSDate.rs_dateWithNumberOfDays(inThePast: 4 * 31)!

	init(name: String, accountID: String, queue: RSDatabaseQueue) {

		self.name = name
		self.accountID = accountID
		self.queue = queue
		self.statusesTable = StatusesTable(queue: queue)
		
		let authorsTable = AuthorsTable(name: DatabaseTableName.authors)
		self.authorsLookupTable = DatabaseLookupTable(name: DatabaseTableName.authorsLookup, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.authorID, relatedTable: authorsTable, relationshipName: RelationshipName.authors)
		
		let tagsTable = TagsTable(name: DatabaseTableName.tags)
		self.tagsLookupTable = DatabaseLookupTable(name: DatabaseTableName.tags, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.tagName, relatedTable: tagsTable, relationshipName: RelationshipName.tags)
		
		let attachmentsTable = AttachmentsTable(name: DatabaseTableName.attachments)
		self.attachmentsLookupTable = DatabaseLookupTable(name: DatabaseTableName.attachmentsLookup, objectIDKey: DatabaseKey.articleID, relatedObjectIDKey: DatabaseKey.attachmentID, relatedTable: attachmentsTable, relationshipName: RelationshipName.attachments)
	}

	// MARK: Fetching
	
	func fetchArticles(_ feed: Feed) -> Set<Article> {
		
		let feedID = feed.feedID
		var articles = Set<Article>()

		queue.fetchSync { (database) in
			articles = self.fetchArticlesForFeedID(feedID, withLimits: true, database: database)
		}

		return articles
	}

	func fetchArticlesAsync(_ feed: Feed, withLimits: Bool, _ resultBlock: @escaping ArticleResultBlock) {

		let feedID = feed.feedID

		queue.fetch { (database) in

			let articles = self.fetchArticlesForFeedID(feedID, withLimits: withLimits, database: database)

			DispatchQueue.main.async {
				resultBlock(articles)
			}
		}
	}
	
	func fetchUnreadArticles(for feeds: Set<Feed>) -> Set<Article> {

		return fetchUnreadArticles(feeds.feedIDs())
	}

	// MARK: Updating
	
	func update(_ feed: Feed, _ parsedFeed: ParsedFeed, _ completion: @escaping UpdateArticlesWithFeedCompletionBlock) {

		if parsedFeed.items.isEmpty {
			completion(nil, nil)
			return
		}

		// 1. Create incoming articles with parsedItems.
		// 2. Ensure statuses for all the incoming articles.
		// 3. Ignore incoming articles that are userDeleted || (!starred and really old)
		// 4. Fetch all articles for the feed.
		// 5. Create array of Articles not in database and save them.
		// 6. Create array of updated Articles and save what’s changed.
		// 7. Call back with new and updated Articles.
		
		let feedID = feed.feedID
		
		self.queue.run { (database) in
			
			// This doesn’t hit the database, but it should be done on the database queue.
			let allIncomingArticles = Article.articlesWithParsedItems(parsedFeed.items, self.accountID, feedID) //1
			if allIncomingArticles.isEmpty {
				self.callUpdateArticlesCompletionBlock(nil, nil, completion)
				return
			}
			
			DispatchQueue.main.async {
				self.ensureStatusesAndSaveArticles(allIncomingArticles, feedID, completion) //2-7
			}
		}
	}

	// MARK: Unread Counts
	
	func fetchUnreadCounts(_ feeds: Set<Feed>, _ completion: @escaping UnreadCountCompletionBlock) {
		
		let feedIDs = feeds.feedIDs()
		var unreadCountDictionary = UnreadCountDictionary()

		queue.fetch { (database) in

			for feedID in feedIDs {
				unreadCountDictionary[feedID] = self.fetchUnreadCount(feedID, database)
			}

			DispatchQueue.main.async() {
				completion(unreadCountDictionary)
			}
		}
	}

	// MARK: Status
	
	func mark(_ articles: Set<Article>, _ statusKey: String, _ flag: Bool) {

		statusesTable.mark(articles.statuses(), statusKey, flag)
	}
}

// MARK: - Private

private extension ArticlesTable {

	// MARK: Fetching

	func articlesWithResultSet(_ resultSet: FMResultSet, _ database: FMDatabase) -> Set<Article> {

		// Create set of stub Articles without related objects.
		// Then fetch the related objects, given the set of articleIDs.
		// Then create set of Articles *with* related objects and return it.

		let (stubArticles, statuses) = stubArticlesAndStatuses(with: resultSet)
		
		statusesTable.addIfNotCached(statuses)
		if stubArticles.isEmpty {
			return stubArticles
		}
		
		// Fetch related objects.
		
		let articleIDs = stubArticles.articleIDs()
		let authorsMap = authorsLookupTable.fetchRelatedObjects(for: articleIDs, in: database)
		let attachmentsMap = attachmentsLookupTable.fetchRelatedObjects(for: articleIDs, in: database)
		let tagsMap = tagsLookupTable.fetchRelatedObjects(for: articleIDs, in: database)
		
		if authorsMap == nil && attachmentsMap == nil && tagsMap == nil {
			return stubArticles
		}
		
		// Create articles with related objects.

		let articles = Set(stubArticles.map { articleWithAttachedRelatedObjects($0, authorsMap, attachmentsMap, tagsMap) })
		return articles
	}

	func stubArticlesAndStatuses(with resultSet: FMResultSet) -> (Set<Article>, Set<ArticleStatus>) {

		var stubArticles = Set<Article>()
		var statuses = Set<ArticleStatus>()

		// Note: the resultSet is a result of a JOIN query with the statuses table,
		// so we can get the statuses at the same time and avoid additional database lookups.

		while resultSet.next() {
			if let stubArticle = Article(row: resultSet, accountID: accountID) {
				stubArticles.insert(stubArticle)
			}
			if let status = statusesTable.statusWithRow(resultSet) {
				statuses.insert(status)
			}
		}
		resultSet.close()

		return (stubArticles, statuses)
	}

	func articleWithAttachedRelatedObjects(_ stubArticle: Article, _ authorsMap: RelatedObjectsMap?, _ attachmentsMap: RelatedObjectsMap?, _ tagsMap: RelatedObjectsMap?) -> Article {

		let articleID = stubArticle.articleID

		let authors = authorsMap?.authors(for: articleID)
		let attachments = attachmentsMap?.attachments(for: articleID)
		let tags = tagsMap?.tags(for: articleID)

		let realArticle = stubArticle.articleByAttaching(authors, attachments, tags)
		return realArticle
	}

	func fetchArticlesWithWhereClause(_ database: FMDatabase, whereClause: String, parameters: [AnyObject], withLimits: Bool) -> Set<Article> {

		// Don’t fetch articles that shouldn’t appear in the UI. The rules:
		// * Must not be deleted.
		// * Must be either 1) starred or 2) dateArrived must be newer than cutoff date.

		let sql = withLimits ? "select * from articles natural join statuses where \(whereClause) and userDeleted=0 and (starred=1 or dateArrived>?);" : "select * from articles natural join statuses where \(whereClause);"
		return articlesWithSQL(sql, parameters + [articleCutoffDate as AnyObject], database)
	}

	func fetchUnreadCount(_ feedID: String, _ database: FMDatabase) -> Int {
		
		// Count only the articles that would appear in the UI.
		// * Must be unread.
		// * Must not be deleted.
		// * Must be either 1) starred or 2) dateArrived must be newer than cutoff date.

		let sql = "select count(*) from articles natural join statuses where feedID=? and read=0 and userDeleted=0 and (starred=1 or dateArrived>?);"
		return numberWithSQLAndParameters(sql, [feedID, articleCutoffDate], in: database)
	}
	
	func fetchArticlesForFeedID(_ feedID: String, withLimits: Bool, database: FMDatabase) -> Set<Article> {

		return fetchArticlesWithWhereClause(database, whereClause: "articles.feedID = ?", parameters: [feedID as AnyObject], withLimits: withLimits)
	}

	func fetchUnreadArticles(_ feedIDs: Set<String>) -> Set<Article> {

		if feedIDs.isEmpty {
			return Set<Article>()
		}

		var articles = Set<Article>()

		queue.fetchSync { (database) in

			// select * from articles natural join statuses where feedID in ('http://ranchero.com/xml/rss.xml') and read=0

			let parameters = feedIDs.map { $0 as AnyObject }
			let placeholders = NSString.rs_SQLValueList(withPlaceholders: UInt(feedIDs.count))!
			let whereClause = "feedID in \(placeholders) and read=0"
			articles = self.fetchArticlesWithWhereClause(database, whereClause: whereClause, parameters: parameters, withLimits: true)
		}

		return articles
	}

	func articlesWithSQL(_ sql: String, _ parameters: [AnyObject], _ database: FMDatabase) -> Set<Article> {

		guard let resultSet = database.executeQuery(sql, withArgumentsIn: parameters) else {
			return Set<Article>()
		}
		return articlesWithResultSet(resultSet, database)
	}

	// MARK: Saving Parsed Items
	
	private func ensureStatusesAndSaveArticles(_ allIncomingArticles: Set<Article>, _ feedID: String, _ completion: @escaping UpdateArticlesWithFeedCompletionBlock) {
		
		statusesTable.ensureStatusesForArticleIDs(allIncomingArticles.articleIDs()) { (statusesDictionary) in // 2
			
			self.queue.update{ (database) in
				self.saveArticlesWithDatabase(allIncomingArticles, statusesDictionary, feedID, database, completion)
			}
		}
	}
	
	private func saveArticlesWithDatabase(_ allIncomingArticles: Set<Article>, _ statusesDictionary: [String: ArticleStatus], _ feedID: String, _ database: FMDatabase, _ completion: @escaping UpdateArticlesWithFeedCompletionBlock) { // 3-7
		
		let incomingArticles = filterIncomingArticles(allIncomingArticles, statusesDictionary) //3
		if incomingArticles.isEmpty {
			callUpdateArticlesCompletionBlock(nil, nil, completion)
			return
		}
		
		let fetchedArticles = fetchArticlesForFeedID(feedID, withLimits: false, database: database) //4
		let fetchedArticlesDictionary = fetchedArticles.dictionary()
		
		let newArticles = findAndSaveNewArticles(incomingArticles, fetchedArticlesDictionary, database) //5
		let updatedArticles = findAndSaveUpdatedArticles(incomingArticles, fetchedArticlesDictionary, database) //6
		
		callUpdateArticlesCompletionBlock(newArticles, updatedArticles, completion)
	}
	
	func callUpdateArticlesCompletionBlock(_ newArticles: Set<Article>?, _ updatedArticles: Set<Article>?, _ completion: @escaping UpdateArticlesWithFeedCompletionBlock) {
		
		DispatchQueue.main.async {
			completion(newArticles, updatedArticles)
		}
	}
	
	// MARK: Save New Articles

	func findNewArticles(_ incomingArticles: Set<Article>, _ fetchedArticlesDictionary: [String: Article]) -> Set<Article>? {
		
		let newArticles = Set(incomingArticles.filter { fetchedArticlesDictionary[$0.articleID] == nil })
		return newArticles.isEmpty ? nil : newArticles
	}
	
	func findAndSaveNewArticles(_ incomingArticles: Set<Article>, _ fetchedArticlesDictionary: [String: Article], _ database: FMDatabase) -> Set<Article>? { //5
		
		guard let newArticles = findNewArticles(incomingArticles, fetchedArticlesDictionary) else {
			return nil
		}
		self.saveNewArticles(newArticles, database)
		return newArticles
	}
	
	func saveNewArticles(_ articles: Set<Article>, _ database: FMDatabase) {

		saveRelatedObjectsForNewArticles(articles, database)

		if let databaseDictionaries = articles.databaseDictionaries() {
			insertRows(databaseDictionaries, insertType: .orReplace, in: database)
		}
	}

	func saveRelatedObjectsForNewArticles(_ articles: Set<Article>, _ database: FMDatabase) {

		let databaseObjects = articles.databaseObjects()

		authorsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
		attachmentsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
		tagsLookupTable.saveRelatedObjects(for: databaseObjects, in: database)
	}

	// MARK: Update Existing Articles

	func articlesWithRelatedObjectChanges<T>(_ comparisonKeyPath: KeyPath<Article, Set<T>?>, _ updatedArticles: Set<Article>, _ fetchedArticles: [String: Article]) -> Set<Article> {

		return updatedArticles.filter{ (updatedArticle) -> Bool in
			if let fetchedArticle = fetchedArticles[updatedArticle.articleID] {
				return updatedArticle[keyPath: comparisonKeyPath] != fetchedArticle[keyPath: comparisonKeyPath]
			}
			assertionFailure("Expected to find matching fetched article.");
			return true
		}
	}

	func updateRelatedObjects<T>(_ comparisonKeyPath: KeyPath<Article, Set<T>?>, _ updatedArticles: Set<Article>, _ fetchedArticles: [String: Article], _ lookupTable: DatabaseLookupTable, _ database: FMDatabase) {

		let articlesWithChanges = articlesWithRelatedObjectChanges(comparisonKeyPath, updatedArticles, fetchedArticles)
		if !articlesWithChanges.isEmpty {
			lookupTable.saveRelatedObjects(for: articlesWithChanges.databaseObjects(), in: database)
		}
	}

	func saveUpdatedRelatedObjects(_ updatedArticles: Set<Article>, _ fetchedArticles: [String: Article], _ database: FMDatabase) {

		updateRelatedObjects(\Article.tags, updatedArticles, fetchedArticles, tagsLookupTable, database)
		updateRelatedObjects(\Article.authors, updatedArticles, fetchedArticles, authorsLookupTable, database)
		updateRelatedObjects(\Article.attachments, updatedArticles, fetchedArticles, attachmentsLookupTable, database)
	}

	func findUpdatedArticles(_ incomingArticles: Set<Article>, _ fetchedArticlesDictionary: [String: Article]) -> Set<Article>? {
		
		let updatedArticles = incomingArticles.filter{ (incomingArticle) -> Bool in //6
			if let existingArticle = fetchedArticlesDictionary[incomingArticle.articleID] {
				if existingArticle != incomingArticle {
					return true
				}
			}
			return false
		}

		return updatedArticles.isEmpty ? nil : updatedArticles
	}
	
	func findAndSaveUpdatedArticles(_ incomingArticles: Set<Article>, _ fetchedArticlesDictionary: [String: Article], _ database: FMDatabase) -> Set<Article>? { //6
		
		guard let updatedArticles = findUpdatedArticles(incomingArticles, fetchedArticlesDictionary) else {
			return nil
		}
		saveUpdatedArticles(Set(updatedArticles), fetchedArticlesDictionary, database)
		return updatedArticles
	}
	

	func saveUpdatedArticles(_ updatedArticles: Set<Article>, _ fetchedArticles: [String: Article], _ database: FMDatabase) {

		saveUpdatedRelatedObjects(updatedArticles, fetchedArticles, database)
		
		for updatedArticle in updatedArticles {
			saveUpdatedArticle(updatedArticle, fetchedArticles, database)
		}
	}

	func saveUpdatedArticle(_ updatedArticle: Article, _ fetchedArticles: [String: Article], _ database: FMDatabase) {
		
		// Only update exactly what has changed in the Article (if anything).
		// Untested theory: this gets us better performance and less database fragmentation.
		
		guard let fetchedArticle = fetchedArticles[updatedArticle.articleID] else {
			assertionFailure("Expected to find matching fetched article.");
			saveNewArticles(Set([updatedArticle]), database)
			return
		}
		
		guard let changesDictionary = updatedArticle.changesFrom(fetchedArticle), changesDictionary.count > 0 else {
			// Not unexpected. There may be no changes.
			return
		}
		
		updateRowsWithDictionary(changesDictionary, whereKey: DatabaseKey.articleID, matches: updatedArticle.articleID, database: database)
	}
	
	func statusIndicatesArticleIsIgnorable(_ status: ArticleStatus) -> Bool {

		// Ignorable articles: either userDeleted==1 or (not starred and arrival date > 4 months).

		if status.userDeleted {
			return true
		}
		if status.starred {
			return false
		}
		return status.dateArrived < maximumArticleCutoffDate
	}

	func filterIncomingArticles(_ articles: Set<Article>, _ statuses: [String: ArticleStatus]) -> Set<Article> {
		
		// Drop Articles that we can ignore.
		
		return Set(articles.filter{ (article) -> Bool in
			let articleID = article.articleID
			if let status = statuses[articleID] {
				return !statusIndicatesArticleIsIgnorable(status)
			}
			assertionFailure("Expected a status for each Article.")
			return true
		})
	}
}

