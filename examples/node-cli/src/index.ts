#!/usr/bin/env node

import { Command } from 'commander';
import chalk from 'chalk';
import inquirer from 'inquirer';
import ora from 'ora';
import { LettaLite, AgentConfig } from './letta.js';
import { performance } from 'perf_hooks';

const program = new Command();

program
  .name('letta-cli')
  .description('CLI for testing Letta Lite')
  .version('0.1.0');

// Demo command
program
  .command('demo')
  .description('Run a demo showing all features')
  .option('-m, --model <model>', 'Model to use', 'toy')
  .action(async (options) => {
    console.log(chalk.blue.bold('\nLetta Lite Demo\n'));
    
    const spinner = ora('Initializing Letta Lite...').start();
    
    try {
      // Initialize
      await LettaLite.initialize();
      spinner.succeed('Initialized Letta Lite');
      
      // Create agent
      spinner.start('Creating agent...');
      const config: AgentConfig = {
        name: 'demo-agent',
        systemPrompt: 'You are a helpful medical assistant with knowledge about diabetes management.',
        model: options.model,
      };
      
      const agent = await LettaLite.createAgent(config);
      spinner.succeed('Created agent: demo-agent');
      
      // Set memory blocks
      spinner.start('Setting memory blocks...');
      await agent.setBlock('patient_profile', 'Age 72, Type 2 Diabetes, insulin user');
      await agent.setBlock('recent_vitals', 'Latest HbA1c: 7.2%, Weight: 180 lbs');
      spinner.succeed('Memory blocks configured');
      
      // Add archival data
      spinner.start('Adding archival data...');
      await agent.appendArchival('logs', 'HGT 168 mg/dL at 8:00 AM');
      await agent.appendArchival('logs', 'HGT 112 mg/dL at 12:00 PM');
      await agent.appendArchival('logs', 'Insulin administered: 10 units at 8:15 AM');
      spinner.succeed('Archival data added');
      
      // Test conversation
      console.log(chalk.cyan('\nTesting conversation:\n'));
      
      const queries = [
        'Hello!',
        'Summarize the patient profile',
        'Search for latest glucose readings #DO_SEARCH',
      ];
      
      for (const query of queries) {
        console.log(chalk.yellow(`User: ${query}`));
        
        const start = performance.now();
        const response = await agent.converse(query);
        const elapsed = ((performance.now() - start) / 1000).toFixed(2);
        
        console.log(chalk.green(`Assistant: ${response.text}`));
        console.log(chalk.gray(`  [${elapsed}s, ${response.usage?.totalTokens || 0} tokens]`));
        
        if (response.toolTrace && response.toolTrace.length > 0) {
          console.log(chalk.magenta('  Tool calls:'));
          for (const tool of response.toolTrace) {
            console.log(chalk.magenta(`    - ${JSON.stringify(tool)}`));
          }
        }
        console.log();
      }
      
      // Search archival
      spinner.start('Searching archival memory...');
      const results = await agent.searchArchival('glucose', 3);
      spinner.succeed(`Found ${results.length} archival results`);
      
      for (const result of results) {
        console.log(chalk.gray(`  - ${result.text}`));
      }
      
      // Export AF
      spinner.start('Exporting agent file...');
      const af = await agent.exportAF();
      spinner.succeed(`Exported AF v${af.version} with ${af.agents.length} agent(s)`);
      
      // Show stats
      console.log(chalk.blue.bold('\nDemo Statistics:\n'));
      console.log(`  Agents: ${af.agents.length}`);
      console.log(`  Memory blocks: ${af.blocks.length}`);
      console.log(`  Messages: ${af.agents[0]?.messages.length || 0}`);
      
      // Cleanup
      await agent.destroy();
      console.log(chalk.green.bold('\nDemo completed successfully!\n'));
      
    } catch (error) {
      spinner.fail('Demo failed');
      console.error(chalk.red(error));
      process.exit(1);
    }
  });

// Interactive mode
program
  .command('interactive')
  .description('Interactive chat with an agent')
  .option('-m, --model <model>', 'Model to use', 'toy')
  .action(async (options) => {
    console.log(chalk.blue.bold('\nLetta Lite Interactive Mode\n'));
    
    try {
      await LettaLite.initialize();
      
      const { name, systemPrompt } = await inquirer.prompt([
        {
          type: 'input',
          name: 'name',
          message: 'Agent name:',
          default: 'assistant',
        },
        {
          type: 'input',
          name: 'systemPrompt',
          message: 'System prompt:',
          default: 'You are a helpful AI assistant.',
        },
      ]);
      
      const agent = await LettaLite.createAgent({
        name,
        systemPrompt,
        model: options.model,
      });
      
      console.log(chalk.green(`\nAgent '${name}' created. Type 'exit' to quit.\n`));
      
      while (true) {
        const { message } = await inquirer.prompt([
          {
            type: 'input',
            name: 'message',
            message: chalk.cyan('You:'),
          },
        ]);
        
        if (message.toLowerCase() === 'exit') {
          break;
        }
        
        if (message.startsWith('/')) {
          // Handle commands
          const [cmd, ...args] = message.slice(1).split(' ');
          
          switch (cmd) {
            case 'setblock':
              if (args.length >= 2) {
                const [label, ...valueParts] = args;
                await agent.setBlock(label, valueParts.join(' '));
                console.log(chalk.gray(`Memory block '${label}' updated`));
              }
              break;
              
            case 'getblock':
              if (args.length >= 1) {
                const value = await agent.getBlock(args[0]);
                console.log(chalk.gray(`${args[0]}: ${value || '(empty)'}`));
              }
              break;
              
            case 'archive':
              if (args.length >= 1) {
                await agent.appendArchival('default', args.join(' '));
                console.log(chalk.gray('Added to archival memory'));
              }
              break;
              
            case 'search':
              if (args.length >= 1) {
                const results = await agent.searchArchival(args.join(' '), 3);
                console.log(chalk.gray(`Found ${results.length} results:`));
                results.forEach(r => console.log(chalk.gray(`  - ${r.text}`)));
              }
              break;
              
            case 'export':
              const af = await agent.exportAF();
              console.log(chalk.gray(`Exported AF v${af.version}`));
              break;
              
            case 'help':
              console.log(chalk.gray(`
Commands:
  /setblock <label> <value> - Set memory block
  /getblock <label>         - Get memory block
  /archive <text>           - Add to archival
  /search <query>           - Search archival
  /export                   - Export agent file
  /help                     - Show this help
              `));
              break;
              
            default:
              console.log(chalk.red(`Unknown command: ${cmd}`));
          }
        } else {
          // Regular conversation
          const spinner = ora('Thinking...').start();
          const response = await agent.converse(message);
          spinner.stop();
          
          console.log(chalk.green(`Assistant: ${response.text}`));
          
          if (response.toolTrace && response.toolTrace.length > 0) {
            console.log(chalk.gray('(Used tools:', response.toolTrace.map(t => t.tool).join(', ') + ')'));
          }
        }
        
        console.log();
      }
      
      await agent.destroy();
      console.log(chalk.green('\nGoodbye!\n'));
      
    } catch (error) {
      console.error(chalk.red(error));
      process.exit(1);
    }
  });

// Test command
program
  .command('test')
  .description('Run automated tests')
  .action(async () => {
    console.log(chalk.blue.bold('\nRunning Letta Lite Tests\n'));
    
    const tests = [
      {
        name: 'Initialization',
        fn: async () => {
          await LettaLite.initialize();
        },
      },
      {
        name: 'Agent Creation',
        fn: async () => {
          const agent = await LettaLite.createAgent({ name: 'test-agent' });
          await agent.destroy();
        },
      },
      {
        name: 'Memory Operations',
        fn: async () => {
          const agent = await LettaLite.createAgent();
          await agent.setBlock('test', 'value');
          const value = await agent.getBlock('test');
          if (value !== 'value') throw new Error('Memory mismatch');
          await agent.destroy();
        },
      },
      {
        name: 'Archival Operations',
        fn: async () => {
          const agent = await LettaLite.createAgent();
          await agent.appendArchival('test', 'test data');
          const results = await agent.searchArchival('test', 1);
          if (results.length === 0) throw new Error('Search failed');
          await agent.destroy();
        },
      },
      {
        name: 'Conversation',
        fn: async () => {
          const agent = await LettaLite.createAgent();
          const response = await agent.converse('Hello');
          if (!response.text) throw new Error('No response');
          await agent.destroy();
        },
      },
      {
        name: 'AF Export/Import',
        fn: async () => {
          const agent = await LettaLite.createAgent();
          await agent.setBlock('test', 'export test');
          const af = await agent.exportAF();
          if (!af.version) throw new Error('Invalid AF');
          await agent.destroy();
        },
      },
    ];
    
    let passed = 0;
    let failed = 0;
    
    for (const test of tests) {
      const spinner = ora(test.name).start();
      
      try {
        const start = performance.now();
        await test.fn();
        const elapsed = ((performance.now() - start) / 1000).toFixed(2);
        spinner.succeed(`${test.name} (${elapsed}s)`);
        passed++;
      } catch (error) {
        spinner.fail(`${test.name}: ${error}`);
        failed++;
      }
    }
    
    console.log(chalk.blue.bold(`\nResults: ${passed} passed, ${failed} failed\n`));
    
    if (failed > 0) {
      process.exit(1);
    }
  });

// Sync command
program
  .command('sync')
  .description('Test cloud sync')
  .requiredOption('-k, --api-key <key>', 'Letta API key')
  .option('-e, --endpoint <url>', 'Letta API endpoint', 'http://localhost:8000')
  .action(async (options) => {
    console.log(chalk.blue.bold('\nTesting Cloud Sync\n'));
    
    const spinner = ora('Configuring sync...').start();
    
    try {
      await LettaLite.initialize();
      
      // Configure sync
      await LettaLite.configureSync({
        endpoint: options.endpoint,
        apiKey: options.apiKey,
        syncInterval: 60000,
        autoSync: false,
      });
      spinner.succeed('Sync configured');
      
      // Create and populate agent
      spinner.start('Creating test agent...');
      const agent = await LettaLite.createAgent({
        name: 'sync-test',
        systemPrompt: 'Test agent for sync',
      });
      
      await agent.setBlock('test', 'sync data');
      await agent.converse('Hello from local');
      spinner.succeed('Agent created and populated');
      
      // Sync to cloud
      spinner.start('Syncing to cloud...');
      await agent.syncWithCloud();
      spinner.succeed('Synced to cloud');
      
      // Export for verification
      const af = await agent.exportAF();
      console.log(chalk.green(`Sync test completed. Agent ${af.agents[0].id} synced.`));
      
      await agent.destroy();
      
    } catch (error) {
      spinner.fail('Sync test failed');
      console.error(chalk.red(error));
      process.exit(1);
    }
  });

program.parse();