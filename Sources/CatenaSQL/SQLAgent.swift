import Foundation
import Kitura
import CatenaCore
import LoggerAPI

/** The SQL agent coordinates participation in a dist*/
public class SQLAgent {
	let node: Node<SQLLedger>
	private var counters: [PublicKey: SQLTransaction.CounterType] = [:]
	private let mutex = Mutex()

	public init(node: Node<SQLLedger>) {
		self.node = node
	}

	/** Submit a transaction, after issue'ing a consecutive counter value to it and signing it with the private key
	provided. */
	public func submit(transaction: SQLTransaction, signWith key: PrivateKey) throws -> Bool {
		try self.mutex.locked {
			if let previous = self.counters[transaction.invoker] {
				Log.debug("[SQLAgent] last counter for \(transaction.invoker) was \(previous)")
				transaction.counter = previous + SQLTransaction.CounterType(1)
			}
			else {
				// Look up the counter value
				try self.node.ledger.longest.withUnverifiedTransactions { chain in
					if let previous = try chain.meta.users.counter(for: transaction.invoker) {
						Log.debug("[SQLAgent] last counter for \(transaction.invoker) was \(previous) according to ledger")
						transaction.counter = previous + SQLTransaction.CounterType(1)
					}
					else {
						Log.debug("[SQLAgent] no previous counter for \(transaction.invoker)")
						transaction.counter = SQLTransaction.CounterType(0)
					}
				}
			}

			Log.debug("[SQLAgent] using counter \(transaction.counter) for \(transaction.invoker)")
			self.counters[transaction.invoker] = transaction.counter
		}

		// Submit
		try transaction.sign(with: key)
		return try self.node.receive(transaction: transaction, from: nil)
	}
}

private class SQLAPIEndpointCORS: RouterMiddleware {
    let allowCorsOrigin: String?
    
    init(allowOrigin: String?) {
        self.allowCorsOrigin = allowOrigin
    }
    
    public func handle(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        if let ac = self.allowCorsOrigin {
            response.headers.append("Access-Control-Allow-Origin", value: ac)
            response.headers.append("Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
            response.headers.append("Content-Type", value: "application/json")
            response.headers.append("Access-Control-Allow-Headers", value: "Content-Type, Accept")
            if request.method == .options {
                _ = response.send(status: .OK)
            }
            else {
                next()
            }
        }
        else {
            next()
        }
    }
}

public class SQLAPIEndpoint {
	let agent: SQLAgent
    
    /** Set 'allowCorsOrigin' to the domain name(s) from which requests may be made. Set to nil to
     disallow any requests from other domains, or set to '*' to allow from any domain. */
    public init(agent: SQLAgent, router: Router, allowCorsOrigin: String?) {
		self.agent = agent
        
        let mw = SQLAPIEndpointCORS(allowOrigin: allowCorsOrigin)
        router.options("/api/*", middleware: mw)
        router.get("/api/*", middleware: mw)
        router.post("/api/*", middleware: mw)
    
		router.get("/api", handler: self.handleIndex)
		router.get("/api/block/:hash", handler: self.handleGetBlock)
		router.get("/api/head", handler: self.handleGetLast)
		router.get("/api/journal", handler: self.handleGetJournal)
		router.get("/api/pool", handler: self.handleGetPool)
		router.get("/api/users", handler: self.handleGetUsers)
        router.post("/api/query", handler: self.handleQuery)
        
        router.all("/", middleware: StaticFileServer(path: "./Resources"))
	}
    
    private func handleQuery(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
        do {
            var data = Data(capacity: 1024)
            try _ = request.read(into: &data)
            let query = try JSONSerialization.jsonObject(with: data, options: [])
            
            // Parse the statement
            if let q = query as? [String: Any], let sql = q["sql"] as? String {
                let statement = try SQLStatement(sql)
                
                // Mutating statements are queued
                if statement.isMutating {
                    _ = response.status(.internalServerError)
                    response.send(json: ["message": "Performing mutating queries through this API is not supported at this time."])
                    try response.end()
                    
                    /* TODO: implement mutating queries. Needs identity information from the client (and/or a signed transaction)
                     let transaction = try SQLTransaction(statement: statement, invoker: identity.publicKey, counter: SQLTransaction.CounterType(0))
                     let result = try self.agent.submit(transaction: transaction, signWith: identity.privateKey) */
                }
                else {
                    try self.agent.node.ledger.longest.withUnverifiedTransactions { chain in
                        let anon = try Identity()
                        let context = SQLContext(metadata: chain.meta, invoker: anon.publicKey, block: chain.highest, parameterValues: [:])
                        let ex = SQLExecutive(context: context, database: chain.database)
                        let result = try ex.perform(statement)
                        
                        var res: [String: Any] = [
                            "sql": sql
                        ];
                        
                        if case .row = result.state {
                            res["columns"] = result.columns
                            
                            var rows: [[Any]] = []
                            while case .row = result.state {
                                let values = result.values.map { val in
                                    return val.json
                                }
                                rows.append(values)
                                result.step()
                            }
                            res["rows"] = rows
                        }
                        
                        response.send(json: res)
                        try response.end()
                    }
                }
            }
            else {
                response.status(.badRequest)
                try response.end()
            }
        }
        catch {
            _ = response.status(.internalServerError)
            response.send(json: ["message": error.localizedDescription])
        }
    }

	private func handleIndex(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let longest = self.agent.node.ledger.longest

		var networkTime: [String: Any] = [:]

		if let nt = self.agent.node.medianNetworkTime {
			let d = Date()
			networkTime["ownTime"] = d.iso8601FormattedUTCDate
			networkTime["ownTimestamp"] = Int(d.timeIntervalSince1970)
			networkTime["medianNetworkTime"] = nt.iso8601FormattedUTCDate
			networkTime["medianNetworkTimestamp"] = Int(nt.timeIntervalSince1970)
			networkTime["ownOffsetFromMedianNetworkTimeMs"] = Int(d.timeIntervalSince(nt)*1000.0)
		}

		response.send(json: [
			"uuid": self.agent.node.uuid.uuidString,

			"time": networkTime,

			"longest": [
				"highest": longest.highest.json,
				"genesis": longest.genesis.json
			],

			"peers": self.agent.node.peers.map { (url, peer) -> [String: Any] in
				return peer.mutex.locked {
					let desc: String
					switch peer.state {
					case .new: desc = "new"
					case .connected: desc = "connected"
					case .connecting(since: let d): desc = "connecting since \(d.iso8601FormattedLocalDate)"
					case .failed(error: let e, at: let d): desc = "error(\(e)) at \(d.iso8601FormattedLocalDate)"
					case .ignored(reason: let e): desc = "ignored(\(e))"
					case .queried: desc = "queried"
					case .querying(since: let d): desc = "querying since \(d.iso8601FormattedLocalDate)"
					case .passive: desc = "passive"
					}

					var res: [String: Any] = [
						"url": peer.url.absoluteString,
						"state": desc
					]

					if let ls = peer.lastSeen {
						res["lastSeen"] = ls.iso8601FormattedLocalDate
					}

					if let td = peer.timeDifference {
						res["time"] =  Date().addingTimeInterval(td).iso8601FormattedLocalDate
					}

					return res
				}
			}
		])
		next()
	}

	private func handleGetBlock(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		if let hashString = request.parameters["hash"], let hash = SQLBlock.HashType(hash: hashString) {
			let block = try self.agent.node.ledger.mutex.locked {
				return try self.agent.node.ledger.longest.get(block: hash)
			}

			if let b = block {
				assert(b.isSignatureValid, "returning invalid blocks, that can't be good")
				response.send(json: b.json)

				next()
			}
			else {
				_ = response.send(status: .notFound)
			}
		}
		else {
			_ = response.send(status: .badRequest)
		}
	}

	private func handleGetPool(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let pool = self.agent.node.miner.block?.payload.transactions.map { return $0.json } ?? []

		response.send(json: [
			"status": "ok",
			"pool": pool
		])
		next()
	}

	private func handleGetUsers(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let data = try self.agent.node.ledger.longest.withUnverifiedTransactions { chain in
			return try chain.meta.users.counters()
		}

		var users: [String: Int] = [:]
		data.forEach { user, counter in
			users[user.base64EncodedString()] = counter
		}

		response.send(json: [
			"status": "ok",
			"users": users
		])
		next()
	}

	private func handleGetLast(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let chain = self.agent.node.ledger.longest
		var b: SQLBlock? = chain.highest
		var data: [[String: Any]] = []
		for _ in 0..<10 {
			if let block = b {
				data.append([
					"index": NSNumber(value: block.index),
					"hash": block.signature!.stringValue
					])
				b = try chain.get(block: block.previous)
			}
			else {
				break
			}
		}

		response.send(json: [
			"status": "ok",
			"blocks": data
		])
		next()
	}

	private func handleGetJournal(request: RouterRequest, response: RouterResponse, next: @escaping () -> Void) throws {
		let chain = self.agent.node.ledger.longest
		var b: SQLBlock? = chain.highest
		var data: [String] = [];
		while let block = b {
			data.append("")

			for tr in block.payload.transactions.reversed() {
				data.append(tr.statement.sql(dialect: SQLStandardDialect()) + " -- @\(tr.counter)")
			}

			data.append("-- #\(block.index): \(block.signature!.stringValue)")

			if block.index == 0 {
				break
			}
			b = try chain.get(block: block.previous)
			assert(b != nil, "Could not find block #\(block.index-1):\(block.previous.stringValue) in storage while on-chain!")
		}

		response.headers.setType("text/plain", charset: "utf8")
		response.send(data.reversed().joined(separator: "\r\n"))
		next()
	}
}
